add_library(nas_local SHARED local_files.cpp)
target_compile_features(nas_local PRIVATE cxx_std_17)
target_compile_options(nas_local PRIVATE -Wall -Wextra -Werror=return-type)
target_link_libraries(nas_local PRIVATE ace_napi.z)
