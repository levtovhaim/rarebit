# Compiler warnings for our own targets (not third-party ones). RAREBIT_WERROR makes them errors.
# /utf-8 tells MSVC the sources are UTF-8: the tests contain Hebrew string literals.
function(rarebit_set_warnings target)
  if(MSVC)
    target_compile_options(${target} PRIVATE /W4 /permissive- /utf-8 $<$<BOOL:${RAREBIT_WERROR}>:/WX>)
  else()
    target_compile_options(
      ${target}
      PRIVATE -Wall
              -Wextra
              -Wpedantic
              -Wconversion
              -Wsign-conversion
              -Wshadow
              -Wold-style-cast
              -Wnon-virtual-dtor
              $<$<BOOL:${RAREBIT_WERROR}>:-Werror>)
  endif()
endfunction()
