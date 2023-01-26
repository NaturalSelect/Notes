# Algorithm

Disk-oriented DBMS的table、index通常无法放在memory中。

同时operator产生的中间结果也可能无法放入memory中。

我们需要特殊设计的算法对数据进行操作。

我们会使用Buffer Pool Manager处理数据溢出到磁盘的情况。

我们的算法需要最大化循序I/O，让I/O操作的开销最小化。

## External Merge Sort

为什么我们需要排序：
* 在关系模型中，table中的tuple是无序的。
* 计算Aggregation（聚合）`GROUP BY`需要排序。
* 去除重复`DISTINCT`需要排序。

External Merge Sort由以下步骤组成：
1. Spliting（将每次要排序的数据拆分成几个runs）。
2. Sorting（排序每一个runs）。
3. Merging（进行多路归并排序将N个runs合并到一个输出中）。
4. Repeating（重复上述操作，直到所有数据完成排序）。

*NOTE:N为可使用的最大page数-1（有一个page需要存输出）。*

*NOTE:DBMS通常在配置文件中设置有working memory来表示每一个请求的中间操作，能够使用多少内存。*

要使排序可用，working memory至少要能够进行2-WAY External Merge Sort。

## 2-WAY External Merge Sort

当External Merge Sort的N为2时，它是一个2-WAY External Merge Sort。

运行这样的排序，至少需要3个page。

![F1](./F1.jpg)

`N`为需要排序的数据的总页数。

它总共要进行的循环次数（`pass`）为：<code>1 + [log<sub>2</sub>N]</code>。

其中<code>[log<sub>2</sub>N]</code>向上取整。

I/O代价为：`2N * pass`。

## Double Buffering Optimization

通过perfetching对算法进行优化。

在排序时，获取下一个page，减少阻塞的发生。

在排序两个page时，先加载一个page。

![F2](./F2.jpg)

在排序page 1时，后台获取page 2。

![F3](./F3.jpg)

当page 1排序完成时，page 2立即可用。

![F4](./F4.jpg)

## Gernal External Merge Sort

Gernal External Merge Sort是2-WAY External Merge Sort的推广。

它尽可能地利用working memory，进行K-WAY Merge，以尽可能减少I/O代价。

![F5](./F5.jpg)

`N`为需要排序的总页数。

`B`为可用的内存总页数。

它总共要进行的循环次数（`pass`）为：<code>1 + [log<sub>B-1</sub>(N/B)]</code>。

其中<code>[log<sub>B-1</sub>(N/B)]</code>向上取整。

I/O代价为：`2N * pass`。

每一个pass的伪代码为：

```cpp

std::future<page_t> futures[B-1];

for(std::size_t i = 0;i != B-1;++i)
{
    request_read(futures[i],page_ids[i]);
}

for(std::size_t i = 0;i != B-1;++i)
{
    page_t page = get_from(futures[i]);
    sort_page(page);
    write_output(page);
}

```

## Using B+Trees For Sorting

当我们在需要排序的column上拥有一个Clustered B+Tree Index时。

我们就不需要执行External Merge Sort。

可用直接利用这个B+Tree完成输出。

因为Clustered Index与物理布局匹配，我们只进行循序I/O。

![F6](./F6.jpg)

而Non-Clustered Index则需要做大量随机I/O，不能在sort中使用（除非我们有`where`条件否则不考虑使用非clustered的index）。

为了将随机I/O转化为循序I/O，我们需要对获取到的record id进行排序。

把page id小的放在前面，然后使用这些id进行循序扫描。

将扫描到的数据进行排序。

![F7](./F7.jpg)

## Aggregations

有两种方式可以实现Aggregations：
* Sorting。
* Hashing。

无论磁盘有多快，通常hashing的方式会更好。

## Sort Aggregation

当tuple排序好时，排序的key相同的tuple总是相邻。

利用这个特性，就可以进行聚合操作。

```sql
SELECT DISTINCT cid
 FROM enrolled
WHERE grade IN ('B','C')
ORDER BY cid;
```

![F8](./F8.jpg)

## External Hash Aggregation

当我们执行Aggregation时，我们利用working memory构建一个bucket hash table来帮我们完成操作。

External Hash Aggregation由以下几个步骤组成：
1. Partition - 逐页读入数据将tuple放入不同的partition中，相同key的tuple会被放在同一个partition中，每个partition由若个个page组成，当page满时，将page写出。 

![F10](./F10.jpg)

2. ReHash - 对于每个partition，我们构建一个in-memory hash table来计算Aggregation。

`B`为可用的内存总页数。

`N`为数据总页数。

那么我们最大可有`B-1`个partition。

hash table的最大大小大为`B * (B - 1)`。

大概需要<code>$\sqrt{N}$</code>个buffer。

假设使用fudge factor（模糊因子）`f` > 1。

hash table的大小大约是<code>B * $\sqrt{f * N}$</code>。

```sql
SELECT DISTINCT cid
 FROM enrolled
WHERE grade IN ('B','C');
```

进行Partition，将tuple分布在不同的Partition中。

![F9](./F9.jpg)

顺序处理每一个partition，并产生最终结果。

![F12](./F12.jpg)

![F11](./F11.jpg)

![F13](./F13.jpg)

*NOTE:最终结果可能无法放入内存。*

![F14](./F14.jpg)

## Join

## Nested Loop Join

## Sort-Merge Join

## Hash Join