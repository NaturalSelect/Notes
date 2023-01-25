# OS Organization

## Isolation

为了提供Isolation，OS抽象硬件并对user提供这些抽象。

|Hardware|Abstraction|
|-|-|
|CPU Core|Process|
|Disk|File|
|Network Card|Socket|
|Physical Memory|Address Space|

Strong Isolation需要通过hardware实现。

hardware需要提供两个支持：
* User/Kernel Mode。
* Page Table(or Virtual Memory)。

处理器一般会有两种模式：
* User Mode（指令的执行受限制）。
* Kernel Mode（可以执行某些特权指令）。

*NOTE:RISC-V还有一种Machine Mode。*

*NOTE:BIOS将在OS启动前启动，由他负责启动OS。*

*NOTE:Kernel通常也会在app的address space中，方便user使用system call时，传递app address space的memory。*

![F1](./F1.jpg)

## System Call

System call是app将控制权交给kernel，并转化成kernel mode的方式。

在RISC-V这个指令是`ECALL`，接受一个number作为System Call Number。

![F2](./F2.jpg)

例如，当调用`fork()`时，并不是真的执行`fork`的代码，而是将`SYS_FORK`放入参数寄存器`a0`使用`ECALL`指令。

`ECALL`将陷入kernel然后kernel通过检查`a0`寄存器，发现值`SYS_FORK`明白user想要新建一个process，调用相应的函数来完成`fork`。

![F3](./F3.jpg)

*NOTE:在x86、amd64这个指令是`TRAP`。*

在hardware上有个寄存器记录了`trap table（陷阱表）`的地址。

hardware将通过`trap table`来判断应该跳转到哪个System Call。

## Implmentation

Kernel主要有两种设计方式：
* Monolithic Kernel（宏内核）。
* Micro Kernel（微内核）。

## Monolithic Kernel

将所有Kernel Module都集成在一个kernel process中。

优点：System Call只需要一次kernel/user mode切换，性能好。

缺点：代码量大，导致容易出kernel bug。

![F4](./F4.jpg)

## Micro Kernel

Kernel process只有最基础的几个模块，其他模块都在user space中提供。

各个模块通过IPC来通信。

优点：代码量小，kernel容易维护。

缺点：性能不佳，system call导致2次kernel/user mode切换，kernel模块之间不容易共享数据。

![F5](./F5.jpg)

## Compile Process of Kernel

Compiler将C Source File编译成.S 汇编文件。

Assembler将.S 汇编文件编译成.O 二进制对象文件。

Linker将所有的.O链接到一起产生完整kernel可执行文件。

![F6](./F6.jpg)