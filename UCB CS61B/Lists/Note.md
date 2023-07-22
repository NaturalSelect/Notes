# Lists

线性表是最基础的数据结构，按某种顺序存储元素。

## Single Linked List（SLList）

Single Linked List由一系列的nodes组成，每一个node都内嵌一个指向下一个node的pointer。

![F1](./F1.png)

|Operations|Speed|
|-|-|
|Random Access|Slow|
|Random Insert|Fast|
|Random Delete|Fast|
|Sequential Access|Fast|
|Backward Sequential Access|Slow|
|Sequential Insert|Fast|
|Last Delete|Fast|

## Double Linked List（DLList）

Double Linked List由一系列的nodes组成，每一个node都内嵌一个指向下一个node的pointer，以及一个指向上一个node的pointer。

![F4](./F4.png)

|Double Linked List|Circular Linked List|
|-|-|
|![F2](./F2.png)|![F3](./F3.png)|

通常使用环形方法实现。

|Operations|Speed|
|-|-|
|Random Access|Slow|
|Random Insert|Fast|
|Random Delete|Fast|
|Sequential Access|Fast|
|Backward Sequential Access|Fast|
|Sequential Insert|Fast|
|Last Delete|Fast|

## Array List（AList）

Array List由一组在物理上聚集（cluster）在一起的元素，它们的逻辑顺序与它们的物理顺序相同，并且元素之间的存储空间是紧密相连的。

*NOTE：这意味着良好的空间局部性。*

由于物理存储上的连续性，插入和删除都可能需要调整元素的位置（同时可能需要重新分配内存）。

![F5](./F5.png)

*NOTE：通常都会预留空间以便加速插入，扩容时使用的空间一般是原来的两倍。*

|Operations|Speed|
|-|-|
|Random Access|Fast|
|Random Insert|Slow|
|Random Delete|Slow|
|Sequential Access|Fast|
|Backward Sequential Access|Fast|
|Sequential Insert|Fast|
|Last Delete|Fast|

*NOTE：请使用AList作为默认线性数据结构，因为它有较好的局部性。*