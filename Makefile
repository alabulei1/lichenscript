
FLAGS = --std ./std -R ./runtime --base ./examples 

hello_world: compiler
	rm -rf ./_build_wt/hello_world
	mkdir -p ./_build_wt/hello_world
	./_build/default/bin/main.exe run ./examples/hello_world/main.lc \
		$(FLAGS) -D ./_build_wt/hello_world

fibonacci: compiler
	rm -rf ./_build_wt/fibonacci
	mkdir -p ./_build_wt/fibonacci
	./_build/default/bin/main.exe run ./examples/fibonacci/main.wt \
		$(FLAGS) -D ./_build_wt/fibonacci

class: compiler
	rm -rf ./_build_wt/class
	mkdir -p ./_build_wt/class
	./_build/default/bin/main.exe run ./examples/class/main.wt \
		$(FLAGS) -D ./_build_wt/class

enum: compiler
	rm -rf ./_build_wt/enum
	mkdir -p ./_build_wt/enum
	./_build/default/bin/main.exe run ./examples/enum/main.wt \
		$(FLAGS) -D ./_build_wt/enum

lambda: compiler
	rm -rf ./_build_wt/lambda
	mkdir -p ./_build_wt/lambda
	./_build/default/bin/main.exe run ./examples/lambda/main.wt \
		$(FLAGS) -D ./_build_wt/lambda

compiler:
	dune build
