# Compile options for our own targets (not third-party ones): warnings and hardening.
function(rarebit_compile_options target)
  if(MSVC)
    # /utf-8: the sources are UTF-8 (the tests contain Hebrew string literals).
    # /sdl: extra security checks; /guard:cf: Control Flow Guard.
    target_compile_options(${target} PRIVATE /W4 /permissive- /utf-8 /sdl /guard:cf
                                             $<$<BOOL:${RAREBIT_WERROR}>:/WX>)
    get_target_property(type ${target} TYPE)
    if(type STREQUAL "EXECUTABLE")
      target_link_options(${target} PRIVATE /guard:cf)
    endif()
    return()
  endif()

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
            $<$<BOOL:${RAREBIT_WERROR}>:-Werror>
            # Hardening: stack canaries, bounds checks in the standard library (no ABI change),
            # and stack-clash probes on Linux.
            -fstack-protector-strong
            -D_GLIBCXX_ASSERTIONS
            $<$<PLATFORM_ID:Linux>:-fstack-clash-protection>
            # _FORTIFY_SOURCE needs optimization (glibc warns at -O0) and doesn't mix with the
            # sanitizers. Undefine it first: some toolchains (Ubuntu's GCC) already define it,
            # and the redefinition warning would be an error under -Werror.
            "$<$<AND:$<NOT:$<CONFIG:Debug>>,$<NOT:$<BOOL:${RAREBIT_SANITIZE}>>>:-U_FORTIFY_SOURCE;-D_FORTIFY_SOURCE=3>")
endfunction()
