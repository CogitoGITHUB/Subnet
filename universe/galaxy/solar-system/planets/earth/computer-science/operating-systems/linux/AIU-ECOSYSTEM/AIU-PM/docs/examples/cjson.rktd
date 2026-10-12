(spec
  (format-version 2)
  (name cjson)
  (version "1.7.19")
  (summary "Ultralight JSON parser in C")
  (source (git "https://github.com/DaveGamble/cJSON.git"
               "c859b25da02955fef659d658b8f324b5cde87be3"))
  (build (steps
    (cmake-configure #:srcdir "." #:builddir "build"
      #:defines (("ENABLE_CJSON_TEST" "OFF")
                 ("ENABLE_CJSON_UTILS" "OFF")
                 ("BUILD_SHARED_AND_STATIC_LIBS" "OFF")
                 ("CMAKE_BUILD_TYPE" "Release")))
    (cmake-build #:builddir "build")
    (cmake-install #:builddir "build")))
  (install (prefix
    (lib "lib/libcjson.so")
    (include "include/cjson/cJSON.h")
    (lib "lib/pkgconfig/libcjson.pc")
    (lib "lib/cmake/cJSON/cJSONConfig.cmake")
    (check "sh" "-c" "set -e;
      printf '#include <cjson/cJSON.h>\nint main(){cJSON_Delete(' > $PREFIX/.check-t.c;
      printf 'cJSON_CreateObject());return 0;}' >> $PREFIX/.check-t.c;
      cc -I$PREFIX/include $PREFIX/.check-t.c -L$PREFIX/lib -lcjson -o $PREFIX/.check-t;
      LD_LIBRARY_PATH=$PREFIX/lib $PREFIX/.check-t;
      rm -f $PREFIX/.check-t.c $PREFIX/.check-t")))
  (license mit)
  (homepage "https://github.com/DaveGamble/cJSON"))
