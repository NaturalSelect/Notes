# B-Trees

B-Trees是另一种实现关联容器或者索引（index）的方式。

以一种高明的做法避免BST的不平衡问题，通常被使用在存储服务中（DBMS、File System等）。

当B-Tree的最大子树数量`L`为`3`时，通常被称为 2-3-4 Tree和 2-4 Tree。

*NOTE：因为 2-3-4 树 用有 0到3个子树*

另请参阅：[Tree Index](../../CMU%2015-445/Tree%20Indexs/Note.md)

## B+ Trees(In-Memory) Pseudo Code

### Definations

```cpp
constexpr std::size_t Ways = 3;

constexpr std::size_t MaxKeys = Ways - 1;

struct LeafNode {
    LeafNode *prev;
    Pair pairs[MaxKeys];
    LeafNode *next;
};

struct InnerNode {
    BTNode *pairs[MaxKeys];
    BTNode *max;
};

struct BTNode{
    Type nodeType;
    union {
        LeafNode leaf;
        InnerNode inner;
    };
};
```

### Helpers

```cpp
BTNode *FindWay(InnerNode &node,Key key) {
    size_t keys = node.GetPairCount();
    for(size_t i = 0; i != keys; ++i) {
        if(node.pairs[i].Key > key) {
            return pairs[i].Value;
        }
    }
    return node.max;
}

template<typename _Node>
bool IsSafe(_Node &node,OpType op) {
    if(op == Insert) {
        return node.GetPairCount() != maxKeys;
    } else if(op == Delete) {
        return node.GetPairCount() > (maxKeys + 1)/2;
    }
    return true;
}

Stack<BTNode*> GetPath(Key key,OpType op) {
    Stack<BTNode*> path;
    BTNode *node = root;
    while(node->Type != Leaf) {
        if(IsSafe(node->Inner,op)) {
            path.Clear();
        }
        path.Push(node);
        node = FindWay(node->Inner,key);
    }
    return path;
}

void RebalanceLeafs(LeafNode &left,LeafNode &right) {
    size_t count = left.GetPairCount() + right.GetPairCount();
    size_t avgCount = (count + 1)/2;
    if(leaf.GetPairCount() > avgCount) {
        right.PushFront(left.Begin() + avgCount,left.End());
        left.Erase(left.Begin() + avgCount,left.End());
    } else if(right.GetPairCount() > avgCount) {
        size_t tmp = right.GetPairCount() - avgCount;
        left.PushBack(right.Begin(),right.Begin() + tmp);
        right.Erase(right.Begin(),right.Begin() + tmp);
    }
}

void ReblanceInners(InnerNode &left,InnerNode &right) {
    size_t count = left.GetPairCount() + right.GetPairCount() + 2;
    size_t avgCount = (count + 1)/2;
    if(leaf.GetPairCount() + 1 > avgCount) {
        // move max field
        right.PushFront(Pair{left.max.First().Key,left.max});
        left.max = left.Last().Val;
        left.PopBack();
        // balance pairs
        size_t tmp = avgCount - 1;
        right.PushFront(left.Begin() + tmp,left.End());
        left.Erase(left.Begin() + tmp,left.End());

    } else if(right.GetPairCount() + 1 > avgCount) {
        // move max field
        Pair first = right.First();
        right.PopFront();
        left.PushBack(Pair{first.Key,left.max});
        left.max = first.Val;
        // balance pairs
        size_t tmp = right.GetPairCount() - avgCount;
        left.PushBack(right.Begin(),right.Begin() + tmp);
        right.Erase(right.Begin(),right.Begin() + tmp);
    }
}

size_t FindSlot(InnerNode &node,Key key) {
    size_t count = node.GetPairCount();
    size_t i = 0;
    while(i != count) {
        if(node.At(i).Key > key) {
            break;
        }
    }
    return i;
}
```

### Insert

```cpp
Pair InsertToFullLeaf(LeafNode &node,Key key,Val val) {
    if(key > node.Last().Key) {
        return {key,val};
    }
    Pair last = node.Last();
    node.Insert(key,val);
    return last;
}

BTNode *InsertToFullInner(InnerNode &node,Key key,BTNode *child) {
    // if key > max.LastKey()
    // do nothing
    BTNode *max = node.max;
    if(key > max->LastKey()) {
        max = child;
    }
    else if(key > node.Last().Key) {
        // if key  > last key
        // become new max
        node.max = child;
    } else {
        // insert and pop last
        node.max = node.Last().Val;
        node.Insert(key,child);
    }
    return max;
}

void InsertToNotFullInner(InnerNode &node,Key key,BTNode *child) {
    BTNode *max = node.max;
    // if > max replace max
    if(max == nullptr) {
        node.max = child;
        return;
    }
    if(max->LastKey() < key) {
        node.Insert(child->FirstKey(),max);
        node.max = child;
        return;
    }
    node.Insert(key,child);
}

BTNode *InsertToUpper(InnerNode &upper,BTNode *left,BTNode *right) {
    Key key;
    size_t leftSlot = FindSlot(upper,left->Leaf.First().Key);
    if(leftSlot != upper.GetPairCount()) {
        upper.SetKeyAt(leftSlot,right->Leaf.First().Key);
        size_t rightSlot = leftSlot + 1;
        if(rightSlot != upper.GetPairCount()) {
            key = upper.At(rightSlot)->FirstKey();
        } else {
            key = upper.max->FirstKey();
        }
    } else {
        key = INF;
    }
    if(IsSafe(upper,Insert)) {
        InsertToNotFullInner(upper,key,right);
        return nullptr;
    }
    BTNode *max = InsertToFullInner(upper,key,right);
    BTNode *newInner = NewInner();
    InsertToNotFullInner(newInner,INF,max);
    return newInner;
}

void Insert(Key key,Value val) {
    if(root == nullptr) {
        root = NewLeaf();
        root.Insert(key,val);
        return;
    }
    Stack<BTNode*> path = GetPath(key,Insert);
    BTNode *leaf = path.Top();
    path.Pop();
    if(IsSafe(leaf->Leaf,Insert)) {
        leaf->Leaf.Insert(key,val);
        return;
    }
    BTNode *newNode = NewLeaf();
    key,val = InsertToFullLeaf(leaf->Leaf,key,val);
    newNode->Leaf.Insert(key,val);
    // set left and right nodes
    BTNode *left = leaf;
    BTNode *right = newNode;
    bool isLeaf = true;
    while(!path.Empty() && right != nullptr) {
        // get upper node
        BTNode *upper = path.Top();
        path.Pop();
        // rebalance two nodes
        if(!isLeaf) {
            // rebalance inner nodes
            RebalanceInners(left->Inner,right->Inner);
        } else {
            // rebalance leaf nodes
            RebalanceLeafs(leaf->Leaf,newNode->Leaf);
            // set next pointers
            newNode->Leaf.next = leaf->Leaf.next;
            leaf->Leaf.next = newNode;
            isLeaf = false;
        }
        // insert to upper
        newNode = InsertToUpper(upper->Inner,left,right);
        left = upper;
        right = newNode;
    }
    // if right != nullptr
    // it means that we must split root
    if(right != nullptr) {
        BTNode *newRoot = NewInner();
        // insert to new root
        InsertToUpper(newRoot->Inner,left,right);
        if(!isLeaf) {
            // rebalance inner nodes
            RebalanceInners(left->Inner,right->Inner);
        } else {
            // rebalance leaf nodes
            RebalanceLeafs(left->Leaf,right->Leaf);
            // set next pointers
            newNode->Leaf.next = leaf->Leaf.next;
            leaf->Leaf.next = newNode;
        }
        // change root
        root = newRoot;
    }
}
```

### Delete

```cpp
void MergeLeafNodes(LeafNode &left,LeafNode &right) {
    left.PushBack(right.Begin(),right.End());
}

void MergeInnerNodes(InnerNode &left,InnerNode &right) {
    if(left.max != nullptr) {
        left.PushBack({right.FirstKey(),left.max});
    }
    left.PushBack(right.Begin(),right.End());
    left.max = right.max;
}

MergePair GetMergePair(InnerNode &upper,BTNode *node) {
    size_t slot = FindSlot(upper,node->FirstKey());
    if(slot == upper.GetPairCount()) {
        return {upper.Last(),node};
    }
    slot += 1;
    if(slot == upper.GetPairCount()) {
        return {node,upper.max};
    }
    return {node,upper.At(slot)};
}

void DeleteFromInner(InnerNode &upper,BTNode *left,BTNode *right) {
    size_t leafSlot = FindSlot(left->FirstKey());
    size_t rightSlot = leafSlot + 1;
    if(rightSlot == upper.GetPairCount()) {
        upper.PopBack();
        delete upper.max;
        upper.max = left;
        return;
    }
    upper.EraseAt(rightSlot);
    delete right;
}

void Delete(Key key) {
    Stack<BTNode*> path = GetPath(key,Insert);
    BTNode *leaf = path.Top();
    path.Pop();
    if(IsSafe(leaf->Leaf,Delete) || leaf == root) {
        leaf->Leaf.Delete(key);
        return;
    }
    bool isLeaf = true;
    BTNode *left = leaf;
    while(!path.Empty() && left != nullptr) {
        BTNode *upper = path.Top();
        path.Pop();
        BTNode *left,*right = GetMergePair(upper->Inner,left);
        if(isLeaf) {
            isLeaf = false;
            if(left->GetPairCount() + right->GetPairCount() - 1 <= MaxKeys) {
                // merge two leaf nodes
                leaf->Leaf.Delete(key);
                MergeLeafNodes(left->Leaf,right->Leaf);
                // check delete safe or not
                bool safe = IsSafe(upper->Inner,Delete);
                DeleteFromInner(upper->Inner,left,right);
                left = nullptr;
                if(!safe) {
                    left = upper;
                }
            } else {
                size_t leftSlot = FindSlot(upper->Inner,left->FirstKey());
                // rebalance leaf nodes
                RebalanceLeafs(left->Leaf,right->Leaf);
                upper->Inner.SetKeyAt(leftSlot,right->FirstKey());
                left = nullptr;
            }
        } else {
            if(left->GetPairCount() + right->GetPairCount() + 1 <= MaxWays) {
                // merge two inner nodes
                MergeInnerNodes(left->Inner,right->Inner);
                // check delete safe or not
                bool safe = IsSafe(upper->Inner,Delete);
                DeleteFromInner(upper->Inner,left,right);
                left = nullptr;
                if(!safe) {
                    left = upper;
                }
            } else {
                size_t leftSlot = FindSlot(upper->Inner,left->FirstKey());
                // rebalance inner nodes
                RebalanceInners(left->Inner,right->Inner);
                upper->Inner.SetKeyAt(leftSlot,right->FirstKey());
                left = nullptr;
            }
        }
    }
    // if left != nullptr
    // it means that we must merge root
    if(left != nullptr) {
        BTNode *upper = root;
        BTNode *left,*right = GetMergePair(upper->Inner,left);
        if(isLeaf) {
            // merge two leaf nodes
            leaf->Leaf.Delete(key);
            MergeLeafNodes(left->Leaf,right->Leaf);
            DeleteFromInner(upper->Inner,left,right);
        } else {
            // merge two inner nodes
            MergeInnerNodes(left->Inner,right->Inner);
            DeleteFromInner(upper->Inner,left,right);
        }
        delete root;
        root = left;
    }
}
```

### Search

```cpp
BTNode *Search(Key key) {
    if(root == nullptr) {
        return nullptr;
    }
    BTNode *node = root;
    while(node->Type != Leaf) {
        node = FindWay(node->Inner,key);
    }
    if(node->Exists(key)) {
        return node;
    }
    return nullptr;
}
```