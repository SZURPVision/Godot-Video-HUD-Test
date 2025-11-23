# GODOT视频流+HUD+3D测试
## 测试流程:
**复制无人机内录视频到同目录下,并命名为`test.avi`**

编译推流器:
```shell
cd sender_cpp
cmake -B build && cmake --build build 
```
回到项目根目录

启动推流器,其中`127.0.0.1`是目标设备,可不写\
固定推送视频流到9999端口,其他数据到9998
```shell
sender_cpp/build/sender 127.0.0.1
```
推流器需要预热(读取到缓存来保证速度),等到推流器显示帧率即可,此后会进行全速推流

使用`Godot 4.5` 打开`godot/project.godot`

运行Godot接收端