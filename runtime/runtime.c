
#include "runtime.h"
#include "string.h"
#include "time.h"
#include "stdio.h"

#define LC_INIT_SYMBOL_BUCKET_SIZE 128
#define LC_INIT_CLASS_META_CAP 8
#define I64_POOL_SIZE 1024

#define lc_raw_malloc malloc
#define lc_raw_realloc realloc
#define lc_raw_free free

typedef struct LCClassMeta {
    LCClassDef* cls_def;
    LCClassMethodDef* cls_method;
    size_t cls_method_size;
} LCClassMeta;

typedef struct LCRuntime {
    LCMallocState malloc_state;
    uint32_t seed;
    LCSymbolBucket* symbol_buckets;
    uint32_t symbol_bucket_size;
    uint32_t symbol_len;
    LCValue* i64_pool;
    LCBox64* i64_pool_space;
    uint32_t cls_meta_cap;
    uint32_t cls_meta_size;
    LCClassMeta* cls_meta_data;
} LCRuntime;

typedef struct LCArray {
    LC_OBJ_HEADER
    uint32_t len;
    uint32_t capacity;
    LCValue* data;
} LCArray;

static inline uint32_t hash_string8(const uint8_t *str, size_t len, uint32_t h)
{
    size_t i;

    for(i = 0; i < len; i++)
        h = h * 263 + str[i];
    return h;
}

static inline uint32_t hash_string16(const uint16_t *str,
                                     size_t len, uint32_t h)
{
    size_t i;

    for(i = 0; i < len; i++)
        h = h * 263 + str[i];
    return h;
}

// -511 - 512 is the range in the pool
static LCValue* init_i64_pool(LCRuntime* rt) {
    LCValue* result = (LCValue*)lc_malloc(rt, sizeof(LCValue) * I64_POOL_SIZE);

    rt->i64_pool_space = (LCBox64*)lc_malloc(rt, sizeof (LCBox64) * I64_POOL_SIZE);

    int i;
    for (i = 0; i < I64_POOL_SIZE; i++) {
        int val = I64_POOL_SIZE / 2 - i;
        LCBox64* ptr = rt->i64_pool_space + i;
        ptr->i64 = val;
        ptr->header.count = LC_NO_GC;
        result[i].tag = LC_TY_BOXED_I64;
        result[i].ptr_val = (LCObject*)ptr;
    }

    return result;
}

static void free_i64_pool(LCRuntime* rt) {
    lc_free(rt, rt->i64_pool_space);
    lc_free(rt, rt->i64_pool);
}

static void LCFreeObject(LCRuntime* rt, LCValue val);

static inline void LCFreeLambda(LCRuntime* rt, LCValue val) {
    LCLambda* lambda = (LCLambda*)val.ptr_val; 
    size_t i;
    for (i = 0; i < lambda->captured_values_size; i++) {
        LCRelease(rt, lambda->captured_values[i]);
    }

    lc_free(rt, lambda);
}

/**
 * extract the finalizer from the class definition
 */
static void LCFreeClassObject(LCRuntime* rt, LCValue val) {
    LCObject* clsObj = (LCObject*)val.ptr_val;
    LCClassID cls_id = clsObj->header.class_id;
    LCClassMeta* meta = &rt->cls_meta_data[cls_id];
    LCFinalizer finalizer = meta->cls_def->finalizer;
    if (finalizer) {
        finalizer(rt, val);
    }
    lc_free(rt, val.ptr_val);
}

static inline void LCFreeArray(LCRuntime* rt, LCValue val) {
    LCArray* arr = (LCArray*)val.ptr_val;
    uint32_t i;
    for (i = 0; i < arr->len; i++) {
        LCRelease(rt, arr->data[i]);
    }
    if (arr->data != NULL) {
        lc_free(rt, arr->data);
        arr->data = NULL;
    }
    lc_free(rt, arr);
}

static inline void LCFreeRefCell(LCRuntime* rt, LCValue val) {
    LCRefCell* cell = (LCRefCell*)val.ptr_val;
    LCRelease(rt, cell->value);
    lc_free(rt, cell);
}

static void LCFreeObject(LCRuntime* rt, LCValue val) {
    switch (val.tag & 0x7F) {
    case LC_TY_REFCELL:
        LCFreeRefCell(rt, val);
        break;

    case LC_TY_LAMBDA:
        LCFreeLambda(rt, val);
        break;

    case LC_TY_CLASS_OBJECT:
        LCFreeClassObject(rt, val);
        break;

    case LC_TY_ARRAY:
        LCFreeArray(rt, val);
        break;
        
    case LC_TY_STRING:
    case LC_TY_SYMBOL:
    case LC_TY_CLASS_OBJECT_META:
    case LC_TY_BOXED_I64:
    case LC_TY_BOXED_U64:
    case LC_TY_BOXED_F64:
        lc_free(rt, val.ptr_val);
        break;
    
    default:
        fprintf(stderr, "[LichenScript] internal error, unkown tag: %lld\n", val.tag);
        abort();

    }
}

void* lc_malloc(LCRuntime* rt, size_t size) {
    void* ptr = lc_raw_malloc(size);
    if (ptr == NULL) {
        return NULL;
    }
    rt->malloc_state.malloc_count++;
    return ptr;
}

void* lc_mallocz(LCRuntime* rt, size_t size) {
    void* ptr = lc_malloc(rt, size);
    if (ptr == NULL) {
        return NULL;
    }
    memset(ptr, 0, size);
    return ptr;
}

void* lc_realloc(LCRuntime* rt, void* ptr, size_t size) {
    return lc_raw_realloc(ptr, size);
}

void lc_free(LCRuntime* rt, void* ptr) {
    rt->malloc_state.malloc_count--;
    lc_raw_free(ptr);
}

static LCClassDef Object_def = {
    "Object",
    NULL,
};

LCRuntime* LCNewRuntime() {
    LCRuntime* runtime = (LCRuntime*)lc_raw_malloc(sizeof(LCRuntime));
    memset(runtime, 0, sizeof(LCRuntime));
    runtime->malloc_state.malloc_count = 1;

    runtime->seed = time(NULL);

    size_t bucket_size = sizeof(LCSymbolBucket) * LC_INIT_SYMBOL_BUCKET_SIZE;
    LCSymbolBucket* buckets = lc_mallocz(runtime, bucket_size);

    runtime->symbol_buckets = buckets;
    runtime->symbol_bucket_size = LC_INIT_SYMBOL_BUCKET_SIZE;
    runtime->symbol_len = 0;

    runtime->i64_pool = init_i64_pool(runtime);

    runtime->cls_meta_cap = LC_INIT_CLASS_META_CAP;
    runtime->cls_meta_size = 0;
    runtime->cls_meta_data = lc_malloc(runtime, sizeof(LCClassMeta) * runtime->cls_meta_cap);

    // the ancester of all classes
    LCDefineClass(runtime, &Object_def);

    return runtime;
}

void LCFreeRuntime(LCRuntime* rt) {
    uint32_t i;
    LCSymbolBucket* bucket_ptr;
    LCSymbolBucket* next;
    for (i = 0; i < rt->symbol_bucket_size; i++) {
        bucket_ptr = rt->symbol_buckets[i].next;
        while (bucket_ptr != NULL) {
            next = bucket_ptr->next;
            LCFreeObject(rt, bucket_ptr->content);
            bucket_ptr = next;
        }
    }

    lc_free(rt, rt->symbol_buckets);

    free_i64_pool(rt);

    lc_free(rt, rt->cls_meta_data);

    if (rt->malloc_state.malloc_count != 1) {
        fprintf(stderr, "[LichenScript] memory leaks %zu\n", rt->malloc_state.malloc_count);
        lc_raw_free(rt);
        exit(1);
    }

    lc_raw_free(rt);
}

void LCRetain(LCValue val) {
    if (val.tag < 64) {
        return;
    }
    if (val.ptr_val->header.count == LC_NO_GC) {
        return;
    }
    val.ptr_val->header.count++;
}

void LCRelease(LCRuntime* rt, LCValue val) {
    if ((val.tag & 0x7F) < 64) {
        return;
    }
    if (val.ptr_val->header.count == LC_NO_GC) {
        return;
    }
    if (--val.ptr_val->header.count == 0) {
        LCFreeObject(rt, val);
    }
}

void LCInitObject(LCObjectHeader* header, LCObjectType obj_type) {
    header->count = 1;
}

LCValue LCNewStringFromCStringLen(LCRuntime* rt, const unsigned char* content, uint32_t len) {
    uint32_t acquire_len = sizeof(LCString) + len + 1;
    LCString* result = lc_mallocz(rt, acquire_len);
    memset(result, 0, acquire_len);

    LCInitObject(&result->header, LC_TY_STRING);

    memcpy(result->content, content, len);
    
    return (LCValue){ { .ptr_val = (LCObject*)result }, LC_TY_STRING };
}

LCValue LCNewStringFromCString(LCRuntime* rt, const unsigned char* content) {
    return LCNewStringFromCStringLen(rt, content, strlen((const char*)content));
}

LCValue LCNewRefCell(LCRuntime* rt, LCValue value) {
    LCRefCell* cell = (LCRefCell*)lc_mallocz(rt, sizeof(LCRefCell));
    cell->header.count = 1;
    LCRetain(value);
    cell->value = value;
    return (LCValue){ { .ptr_val = (LCObject*)cell }, LC_TY_REFCELL };
}

LCValue LCNewLambda(LCRuntime* rt, LCCFunction c_fun, int argc, LCValue* args) {
    size_t size = sizeof(LCLambda) + argc * sizeof(LCValue);
    LCLambda* lambda = (LCLambda*)lc_mallocz(rt, size);
    lambda->header.count = 1;
    lambda->c_fun = c_fun;
    lambda->captured_values_size = argc;

    size_t i;
    for (i = 0; i < argc; i++) {
        LCRetain(args[i]);
        lambda->captured_values[i] = args[i];
    }

    return (LCValue){ { .ptr_val = (LCObject*)lambda }, LC_TY_LAMBDA };
}

LCValue LCNewSymbolLen(LCRuntime* rt, const char* content, uint32_t len) {
    LCValue result = MK_NULL();
    // LCString* result = NULL;
    uint32_t symbol_hash = hash_string8((const uint8_t*)content, len, rt->seed);
    uint32_t symbol_bucket_index = symbol_hash % rt->symbol_bucket_size;

    LCSymbolBucket* bucket_at_index = &rt->symbol_buckets[symbol_bucket_index];
    LCSymbolBucket* new_bucket = NULL;
    LCString* str_ptr = NULL;

    while (1) {
        if (bucket_at_index->content.tag == LC_TY_NULL) {
            break;
        }

        str_ptr = (LCString*)bucket_at_index->content.ptr_val;
        if (strcmp((const char *)str_ptr->content, content) == 0) {
            result = bucket_at_index->content;
            break;
        }

        if (bucket_at_index->next == NULL) {
            break;
        }
        bucket_at_index = bucket_at_index->next;
    }

    // symbol not found
    if (result.tag == LC_TY_NULL) {
        result = LCNewStringFromCStringLen(rt, (const unsigned char*)content, len);
        result.tag = LC_TY_SYMBOL;
        str_ptr = (LCString*)result.ptr_val;
        str_ptr->header.count = LC_NO_GC;
        str_ptr->hash = hash_string8((const unsigned char*)content, len, rt->seed);

        if (bucket_at_index->content.tag == LC_TY_NULL) {
            bucket_at_index->content = result;
        } else {
            new_bucket = malloc(sizeof(LCSymbolBucket));
            new_bucket->content = result;
            new_bucket->next = NULL;

            bucket_at_index->next = new_bucket;
        }
        rt->symbol_len++;
    }

    // TODO: enlarge symbol map

    return result;
}

LCArray* LCNewArrayWithCap(LCRuntime* rt, size_t cap) {
    LCArray* result = (LCArray*)lc_malloc(rt, sizeof(LCArray));
    result->header.count = 1;
    result->header.class_id = 0;
    result->capacity = cap;
    result->len = 0;
    result->data = (LCValue*)lc_mallocz(rt, sizeof(LCValue) * cap);
    return result;
}

LCValue LCNewArray(LCRuntime* rt) {
    LCArray* arr = LCNewArrayWithCap(rt, 8);
    return (LCValue) { { .ptr_val = (LCObject*)arr },  LC_TY_ARRAY };
}

/**
 * find the nearest number of times of 8
 */
LCValue LCNewArrayLen(LCRuntime* rt, size_t size) {
    size_t remain = size % 8;
    LCArray* arr = LCNewArrayWithCap(rt, size + (8 - remain));
    arr->len = size;
    return (LCValue) { { .ptr_val = (LCObject*)arr },  LC_TY_ARRAY };
}

LCValue LCNewSymbol(LCRuntime* rt, const char* content) {
    return LCNewSymbolLen(rt, content, strlen(content));
}

LCValue LCRunMain(LCProgram* program) {
    if (program->main_fun == NULL) {
        return MK_NULL();
    }
    return program->main_fun(program->runtime, MK_NULL(), 0, NULL);
}

static void std_print_string(LCString* str) {
    printf("%s", str->content);
}

static void std_print_val(LCRuntime* rt, LCValue val) {
    switch (val.tag)
    {
    case LC_TY_BOOL:
        if (val.int_val) {
            printf("true");
        } else {
            printf("false");
        }
        break;

    case LC_TY_F32:
        printf("%f", val.float_val);
        break;

    case LC_TY_I32:
        printf("%d", val.int_val);
        break;

    case LC_TY_NULL:
        printf("()");
        break;

    case LC_TY_STRING:
        std_print_string((LCString*)val.ptr_val);
        break;
    
    default:
        break;
    }

}

LCClassID LCDefineClass(LCRuntime* rt, LCClassDef* cls_def) {
    LCClassID id = rt->cls_meta_size++;

    if (rt->cls_meta_size >= rt->cls_meta_cap) {
        rt->cls_meta_cap *= 2;
        rt->cls_meta_data = lc_realloc(rt, rt->cls_meta_data, sizeof(LCClassMeta) * rt->cls_meta_cap);
    }

    rt->cls_meta_data[id].cls_def = cls_def;

    return id;
}

void LCDefineClassMethod(LCRuntime* rt, LCClassID cls_id, LCClassMethodDef* cls_method, size_t size) {
    LCClassMeta* meta = rt->cls_meta_data + cls_id;
    meta->cls_method = cls_method;
    meta->cls_method_size = size;
}

LCValue LCInvokeStr(LCRuntime* rt, LCValue this, const char* content, int arg_len, LCValue* args) {
    if (this.tag <= 0) {
        fprintf(stderr, "[LichenScript] try to invoke on primitive type");
        abort();
    }

    LCObject* obj = (LCObject*)this.ptr_val;
    LCClassID class_id = obj->header.class_id;
    LCClassMeta* meta = rt->cls_meta_data + class_id;

    size_t i;
    LCClassMethodDef* method_def;
    for (i = 0; i < meta->cls_method_size; i++) {
        method_def = &meta->cls_method[i];
        if (strcmp(method_def->name, content) == 0) {  // this is it
            return method_def->fun_ptr(rt, this, arg_len, args);
        }
    }

    fprintf(stderr, "[LichenScript] Can not find method \"%s\" of class, id: %u\n", content, class_id);
    abort();
    return MK_NULL();
}

LCValue LCEvalLambda(LCRuntime* rt, LCValue this, int argc, LCValue* args) {
    LCLambda* lambda = (LCLambda*)this.ptr_val;
    return lambda->c_fun(rt, this, argc, args);
}

void lc_init_object(LCRuntime* rt, LCClassID cls_id, LCObject* obj) {
    obj->header.count = 1;
    obj->header.class_id = cls_id;
}

LCValue lc_std_print(LCRuntime* rt, LCValue this, int arg_len, LCValue* args) {
    for (int i = 0; i < arg_len; i++) {
        std_print_val(rt, args[i]);
    }
    printf("\n");
    return MK_NULL();
}
