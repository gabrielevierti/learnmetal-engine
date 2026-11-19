# CMake generated Testfile for 
# Source directory: /Users/gabrielevierti/Downloads/learnmetal-engine
# Build directory: /Users/gabrielevierti/Downloads/learnmetal-engine/build
# 
# This file includes the relevant testing commands required for 
# testing this directory and lists subdirectories to be tested as well.
add_test("unit" "/Users/gabrielevierti/Downloads/learnmetal-engine/build/lmtests")
set_tests_properties("unit" PROPERTIES  LABELS "unit" _BACKTRACE_TRIPLES "/Users/gabrielevierti/Downloads/learnmetal-engine/CMakeLists.txt;92;add_test;/Users/gabrielevierti/Downloads/learnmetal-engine/CMakeLists.txt;0;")
add_test("marble-demo" "/Users/gabrielevierti/Downloads/learnmetal-engine/build/marble" "--demo" "--capture" "/Users/gabrielevierti/Downloads/learnmetal-engine/build/marble-demo.png" "--frames" "2400")
set_tests_properties("marble-demo" PROPERTIES  LABELS "gpu" TIMEOUT "600" _BACKTRACE_TRIPLES "/Users/gabrielevierti/Downloads/learnmetal-engine/CMakeLists.txt;94;add_test;/Users/gabrielevierti/Downloads/learnmetal-engine/CMakeLists.txt;0;")
add_test("editor-opens-demo" "/Users/gabrielevierti/Downloads/learnmetal-engine/build/editor" "demo" "--capture" "/Users/gabrielevierti/Downloads/learnmetal-engine/build/editor-demo.png" "--frames" "5")
set_tests_properties("editor-opens-demo" PROPERTIES  LABELS "gpu" TIMEOUT "600" _BACKTRACE_TRIPLES "/Users/gabrielevierti/Downloads/learnmetal-engine/CMakeLists.txt;96;add_test;/Users/gabrielevierti/Downloads/learnmetal-engine/CMakeLists.txt;0;")
add_test("fpv-starts-a-race" "/Users/gabrielevierti/Downloads/learnmetal-engine/build/fpv" "--race" "--capture" "/Users/gabrielevierti/Downloads/learnmetal-engine/build/fpv-race.png" "--frames" "240")
set_tests_properties("fpv-starts-a-race" PROPERTIES  LABELS "gpu" TIMEOUT "600" _BACKTRACE_TRIPLES "/Users/gabrielevierti/Downloads/learnmetal-engine/CMakeLists.txt;98;add_test;/Users/gabrielevierti/Downloads/learnmetal-engine/CMakeLists.txt;0;")
subdirs("_deps/glfw-build")
