# Tries

trie是一种特殊的tree，它的节点只存储key的一个byte。

![F1](./F1.png)

这样有相同前缀的key将会共享一部分内存，同时保留快速的查找和插入能力。

![F2](./F2.png)

为了区分是否遇到了一个完整的key，我们需要给节点设置颜色，蓝色代表从根节点到该节点是一个完整的key。

![F3](./F3.png)

最简单的实现方法是在Node中，存储所有可能出现的byte的Slot。

|Code|Images|
|-|-|
|![F4](./F4.png)|![F5](./F5.png)|

![F6](./F6.png)

## Hash Table Based Trie & BST Based Trie

当然也可以使用Hash Table（或者其他map）代替节点中的大数组。

*NOTE：这种方式称为横向压缩。*

|Hash Table|BST|
|-|-|
|![F7](./F7.png)|![F8](./F8.png)|

![F9](./F9.png)

## Prefix Match

Trie能够高效地支持前缀匹配操作。

![F10](./F10.png)

![F11](./F11.png)

---

另请参阅：
* [Tree Index](../../CMU%2015-445/Tree%20Indexs/Note.md)