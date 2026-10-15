cmake_minimum_required(VERSION 3.16)
project(ECGAIMonitor LANGUAGES CXX)

option(ECG_ENABLE_VITIS_AI "Enable Vitis AI DPU xmodel runtime on Kria/KV260" OFF)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

find_package(Qt5 REQUIRED COMPONENTS Widgets PrintSupport)

add_executable(ECGAIMonitor
    src/main.cpp
    src/ecg_types.h
    src/fixed_beat_library.cpp
    src/fixed_beat_library.h
    src/rhythm_emulator.cpp
    src/rhythm_emulator.h
    src/display_processor.cpp
    src/display_processor.h
    src/signal_buffer.cpp
    src/signal_buffer.h
    src/serial_beat_source.cpp
    src/serial_beat_source.h
    src/demo_controller.cpp
    src/demo_controller.h
    src/demo_window.cpp
    src/demo_window.h
    src/abnormal_review_window.cpp
    src/abnormal_review_window.h
    src/ai/beat_preprocessor.cpp
    src/ai/beat_preprocessor.h
    src/ai/heartbeat_classifier.cpp
    src/ai/heartbeat_classifier.h
    qcustomplot.cpp
    qcustomplot.h
)

target_include_directories(ECGAIMonitor PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_link_libraries(ECGAIMonitor PRIVATE
    Qt5::Widgets
    Qt5::PrintSupport
)

if(ECG_ENABLE_VITIS_AI)
    target_compile_definitions(ECGAIMonitor PRIVATE ECG_ENABLE_VITIS_AI=1)
    find_library(VART_RUNNER_LIBRARY NAMES vart-runner REQUIRED)
    find_library(XIR_LIBRARY NAMES xir REQUIRED)
    find_library(UNILOG_LIBRARY NAMES unilog)
    find_library(GLOG_LIBRARY NAMES glog)
    target_link_libraries(ECGAIMonitor PRIVATE ${VART_RUNNER_LIBRARY} ${XIR_LIBRARY})
    if(UNILOG_LIBRARY)
        target_link_libraries(ECGAIMonitor PRIVATE ${UNILOG_LIBRARY})
    endif()
    if(GLOG_LIBRARY)
        target_link_libraries(ECGAIMonitor PRIVATE ${GLOG_LIBRARY})
    endif()
endif()

add_custom_command(TARGET ECGAIMonitor POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory $<TARGET_FILE_DIR:ECGAIMonitor>/data
    COMMAND ${CMAKE_COMMAND} -E make_directory $<TARGET_FILE_DIR:ECGAIMonitor>/models
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${CMAKE_CURRENT_SOURCE_DIR}/models/ecg_1dcnn_2d_dpu.xmodel
            $<TARGET_FILE_DIR:ECGAIMonitor>/models/ecg_1dcnn_2d_dpu.xmodel
)

# The CPU backend runs the FP32 CNN in a python3 worker, so the script and its
# weights must sit beside the executable exactly as data/ and models/ do.
add_custom_command(TARGET ECGAIMonitor POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory $<TARGET_FILE_DIR:ECGAIMonitor>/python/weights
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${CMAKE_CURRENT_SOURCE_DIR}/python/ecg_cpu_worker.py
            $<TARGET_FILE_DIR:ECGAIMonitor>/python/ecg_cpu_worker.py
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${CMAKE_CURRENT_SOURCE_DIR}/python/weights/ecg1dcnn_weights_float32.npz
            $<TARGET_FILE_DIR:ECGAIMonitor>/python/weights/ecg1dcnn_weights_float32.npz
)

foreach(DATA_FILE sampleN.txt sampleS.txt sampleV.txt sampleF.txt sampleQ.txt)
    add_custom_command(TARGET ECGAIMonitor POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
                ${CMAKE_CURRENT_SOURCE_DIR}/data/${DATA_FILE}
                $<TARGET_FILE_DIR:ECGAIMonitor>/data/${DATA_FILE}
    )
endforeach()
