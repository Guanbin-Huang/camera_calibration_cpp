cpp_srcs := $(shell find src -name "*.cpp")
cpp_objs := $(cpp_srcs:.cpp=.o)
cpp_objs := $(cpp_objs:src/%=objs/%)


lean_opencv    := /datav/Lean/opencv
lean_ceres     := /usr/local/ceres-solver
lean_eigen     := /usr/include/eigen3

include_paths := src        \
			/datav/shared/hgb/camera_calibration/zhihu_cameraCalibration/include \
			/usr/include/suitesparse \
			$(lean_opencv)/include/opencv4 \
			$(lean_ceres)/include/ \
			$(lean_eigen) 

library_paths := $(lean_opencv)/lib    \
			$(lean_ceres)/build/lib \

link_librarys := opencv_core opencv_imgproc opencv_videoio opencv_imgcodecs opencv_calib3d opencv_features2d\
			stdc++ dl ceres gtest test_util glog cholmod \
			lapack blas m cxsparse



paths     := $(foreach item,$(library_paths),-Wl,-rpath=$(item))
include_paths := $(foreach item,$(include_paths),-I$(item))
library_paths := $(foreach item,$(library_paths),-L$(item))
link_librarys := $(foreach item,$(link_librarys),-l$(item))


cpp_compile_flags := -std=c++11 -fPIC -m64 -g -fopenmp -w -O0 $(support_define)
cu_compile_flags  := -std=c++11 -m64 -Xcompiler -fPIC -g -w -gencode=arch=compute_75,code=sm_75 -O0 $(support_define)
link_flags        := -pthread -fopenmp -Wl,-rpath='$$ORIGIN'


cpp_compile_flags += $(include_paths)
cu_compile_flags  += $(include_paths)
link_flags 		  += $(library_paths) $(link_librarys) $(paths)



pro    : workspace/pro


workspace/pro : $(cpp_objs) $(cu_objs)
	@echo Link $@
	@mkdir -p $(dir $@)
	@g++ $^  -o $@ $(link_flags)


objs/%.o : src/%.cpp
	@echo Compile CXX $<
	@mkdir -p $(dir $@)
	@g++ -c $< -o $@ $(cpp_compile_flags)

debug :
	@echo $(includes)

run : workspace/pro
	@cd workspace && ./pro
clean :
	@rm -rf objs workspace/pro python/trtpy/libtrtpyc.so python/build python/dist python/trtpy.egg-info python/trtpy/__pycache__
	@rm -rf workspace/single_inference
	@rm -rf workspace/scrfd_result workspace/retinaface_result
	@rm -rf workspace/YoloV5_result workspace/YoloX_result
	@rm -rf workspace/face/library_draw workspace/face/result
	@rm -rf build
	@rm -rf python/trtpy/libplugin_list.so

.PHONY : clean yolo alphapose fall debug