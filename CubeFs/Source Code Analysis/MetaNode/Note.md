# MetaNode Btree 源码分析

## 背景

在上文《》中，我们已经知道了mp的状态是如何转化的，下面我们来关注mp是如何存储和处理文件系统元数据的。

## 介绍

在CubeFS中，Meta子系统将Inode范围划分成MetaPartition(MP),每个MP存储一个Inode区间内的元数据,CubeFS存储的元数据的种类如下：
* 文件/目录
* 目录项
* 扩展属性（用于对象存储）
* Multipart（用于对象存储）
* 分布式事物信息（事物对象、回滚Inode、回滚Dentry）

每一种元数据都由对应的BTree存储：
* 文件/目录 - InodeTree
* 目录项 - DentryTree
* 扩展属性（用于对象存储） - ExtendTree
* Multipart（用于对象存储） - MultipartTree
* 分布式事物信息（事物对象、回滚Inode、回滚Dentry） - TxTree、TxRbInodeTree、TxRbDentryTree

CubeFS BTree是对 [Google BTree](https://github.com/google/btree) 的简单封装（添加了`sync.RWMutex`）：

```go
type BTree struct {
	sync.RWMutex
	tree *btree.BTree
}
```

使用这个数据结构需要元素类型实现`BTreeItem`接口：

```go
type BtreeItem = btree.Item

type Item interface {
	// Less tests whether the current item is less than the given argument.
	//
	// This must provide a strict weak ordering.
	// If !a.Less(b) && !b.Less(a), we treat this to mean a == b (i.e. we can only
	// hold one of either a or b in the tree).
	Less(than Item) bool
	Copy() Item
}
```

由于MP会占用大量的内存，我们选择BTree这种缓存友好型（cache-friendly）数据结构来存储大量的元数据。

BTree提供以下操作：

```go

func (b *BTree) Get(key BtreeItem) (item BtreeItem) // 获取Btree中的元素(引用)

func (b *BTree) CopyGet(key BtreeItem) (item BtreeItem) // 获取Btree中的元素(拷贝)

func (b *BTree) Find(key BtreeItem, fn func(i BtreeItem)) // 提供一种方便方法： if result = Get(key); result != nil then fn(result)

func (b *BTree) CopyFind(key BtreeItem, fn func(i BtreeItem)) // 同上，但使用拷贝

func (b *BTree) Has(key BtreeItem) (ok bool) // 查看元素是否存在

func (b *BTree) Delete(key BtreeItem) (item BtreeItem) // 删除某个元素，并返回之前的值

func (b *BTree) Execute(fn func(tree *btree.BTree) interface{}) interface{} // 类似 Find,但是加写锁

func (b *BTree) ReplaceOrInsert(key BtreeItem, replace bool) (item BtreeItem, ok bool) // 插入或替换元素, replace将控制是否允许替换, 返回旧元素以及是否发生了替换

func (b *BTree) Ascend(fn func(i BtreeItem) bool) // 升序遍历

func (b *BTree) AscendRange(greaterOrEqual, lessThan BtreeItem, iterator func(i BtreeItem) bool) // 升序遍历某个范围（使用[)区间）

func (b *BTree) AscendGreaterOrEqual(pivot BtreeItem, iterator func(i BtreeItem) bool) // 升序遍历某个范围（使用[]区间）

func (b *BTree) GetTree() *BTree // 获得当前Tree的 COW 一致快照

func (b *BTree) Reset() // 清空 BTree

func (b *BTree) Len() (size int) // 返回Tree的大小

func (b *BTree) MaxItem() BtreeItem // 返回最大的元素
```

## 读元数据操作

Meta子系统的元数据操作都是基于BTree进行的，下面以Inode为例讲解：

一个`stat`系统调用在没有缓存的情况下会被fuse客户端转化成一个`InodeGet`请求进入对应的MP。

```go
// InodeGet executes the inodeGet command from the client.
func (mp *metaPartition) InodeGet(req *InodeGetReq, p *Packet) (err error) {
	var (
		reply      []byte
		status     = proto.OpNotExistErr
		quotaInfos map[uint32]*proto.MetaQuotaInfo
	)
	if mp.mqMgr.EnableQuota() {
		quotaInfos, err = mp.getInodeQuotaInfos(req.Inode)
		if err != nil {
			status = proto.OpErr
			reply = []byte(err.Error())
			p.PacketErrorWithBody(status, reply)
			return
		}
	}
	ino := NewInode(req.Inode, 0)
	retMsg := mp.getInode(ino)
	ino = retMsg.Msg
	if retMsg.Status == proto.OpOk {
		resp := &proto.InodeGetResponse{
			Info: &proto.InodeInfo{},
		}
		if replyInfo(resp.Info, retMsg.Msg, quotaInfos) {
			status = proto.OpOk
			reply, err = json.Marshal(resp)
			if err != nil {
				status = proto.OpErr
				reply = []byte(err.Error())
			}
		}
	}
	p.PacketErrorWithBody(status, reply)
	return
}
```

MP将调用内部函数`getInode`,它将从InodeTree检索数据并构造响应：

```go
func (mp *metaPartition) getInode(ino *Inode) (resp *InodeResponse) {
	resp = NewInodeResponse()
	resp.Status = proto.OpOk
	item := mp.inodeTree.Get(ino) // 从 InodeTree 中获取Inode
	if item == nil {
		resp.Status = proto.OpNotExistErr
		return
	}
	i := item.(*Inode)
	if i.ShouldDelete() {
		resp.Status = proto.OpNotExistErr
		return
	}
	ctime := Now.GetCurrentTimeUnix()
	/*
	 * FIXME: not protected by lock yet, since nothing is depending on atime.
	 * Shall add inode lock in the future.
	 */
	if ctime > i.AccessTime {
		i.AccessTime = ctime
	}

	resp.Msg = i
	return
}
```

## 写元数据操作

写操作比读操作稍微复杂，需要经过Raft，我们以`CreateInode`为例分析：

```go
// CreateInode returns a new inode.
func (mp *metaPartition) CreateInode(req *CreateInoReq, p *Packet, remoteAddr string) (err error) {
	var (
		status = proto.OpNotExistErr
		reply  []byte
		resp   interface{}
		qinode *MetaQuotaInode
		inoID  uint64
	)
	start := time.Now()
	if mp.IsEnableAuditLog() {
		defer func() {
			auditlog.LogInodeOp(remoteAddr, mp.GetVolName(), p.GetOpMsg(), req.GetFullPath(), err, time.Since(start).Milliseconds(), inoID, 0)
		}()
	}
	inoID, err = mp.nextInodeID()
	if err != nil {
		p.PacketErrorWithBody(proto.OpInodeFullErr, []byte(err.Error()))
		return
	}
	ino := NewInode(inoID, req.Mode)
	ino.Uid = req.Uid
	ino.Gid = req.Gid
	ino.LinkTarget = req.Target

	val, err := ino.Marshal()
	if err != nil {
		p.PacketErrorWithBody(proto.OpErr, []byte(err.Error()))
		return err
	}
	resp, err = mp.submit(opFSMCreateInode, val)
	if err != nil {
		p.PacketErrorWithBody(proto.OpAgain, []byte(err.Error()))
		return err
	}

	if resp.(uint8) == proto.OpOk {
		resp := &CreateInoResp{
			Info: &proto.InodeInfo{},
		}
		if replyInfo(resp.Info, ino, make(map[uint32]*proto.MetaQuotaInfo, 0)) {
			status = proto.OpOk
			reply, err = json.Marshal(resp)
			if err != nil {
				status = proto.OpErr
				reply = []byte(err.Error())
			}
		}
	}
	p.PacketErrorWithBody(status, reply)
	log.LogInfof("CreateInode req [%v] qinode [%v] success.", req, qinode)
	return
}
```

在进入对应的MP后，MP会将其转化成Raft命令(`opFSMCreateInode`),该命令会在Raft FSM被处理：

```go
func (mp *metaPartition) Apply(command []byte, index uint64) (resp interface{}, err error) {
    	msg := &MetaItem{}
	defer func() {
		if err == nil {
			mp.uploadApplyID(index)
		}
	}()
	if err = msg.UnmarshalJson(command); err != nil {
		return
	}

	mp.nonIdempotent.Lock()
	defer mp.nonIdempotent.Unlock()

	switch msg.Op {
	case opFSMCreateInode:
		ino := NewInode(0, 0)
		if err = ino.Unmarshal(msg.V); err != nil {
			return
		}
		if mp.config.Cursor < ino.Inode {
			mp.config.Cursor = ino.Inode
		}
		resp = mp.fsmCreateInode(ino)
    // ... 此处省略其他代码
    }
}
```

最后将进入`fsmCreateInode`,操作InodeTree：

```go
// Create and inode and attach it to the inode tree.
func (mp *metaPartition) fsmCreateInode(ino *Inode) (status uint8) {
	log.LogDebugf("action[fsmCreateInode] inode  %v be created", ino.Inode)

	if status = mp.uidManager.addUidSpace(ino.Uid, ino.Inode, nil); status != proto.OpOk {
		return
	}

	status = proto.OpOk
    // 将Inode插入到Btree中
	if _, ok := mp.inodeTree.ReplaceOrInsert(ino, false); !ok {
		status = proto.OpExistErr
	}

	return
}
```

## 总结

本文主要给大家介绍了MetaPartition的BTree接口设计以及，它是如何使用BTree的。如果想了解更多细节欢迎大家阅读源码。

