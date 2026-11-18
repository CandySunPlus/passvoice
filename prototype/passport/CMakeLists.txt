cmake_minimum_required(VERSION 3.16)
project(passvoice_preview C)

set(LV_BUILD_CONF_PATH "${CMAKE_CURRENT_SOURCE_DIR}/lv_conf.h" CACHE FILEPATH "Preview LVGL configuration" FORCE)
set(CONFIG_LV_BUILD_DEMOS OFF CACHE BOOL "Build LVGL demos" FORCE)
set(CONFIG_LV_BUILD_EXAMPLES OFF CACHE BOOL "Build LVGL examples" FORCE)
set(CONFIG_LV_USE_THORVG_INTERNAL OFF CACHE BOOL "Build ThorVG" FORCE)
add_subdirectory("${LVGL_DIR}" lvgl)

add_executable(capture capture.c passvoice_screen.c)
target_link_libraries(capture PRIVATE lvgl)
