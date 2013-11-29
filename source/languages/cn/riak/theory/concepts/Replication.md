---
title: 副本
project: riak
version: 1.4.2+
document: appendix
toc: true
audience: intermediate
keywords: [appendix, concepts]
---

副本是 Riak 的基础，能保证数据的安全性，即使集群中的节点下线了数据仍然存在。Riak 中存储的所有数据都会在一定数量的节点中创建副本，具体的数量由 bucket 的 n_val 属性设定。

<div class="note">
更多内容请阅读“[[在多个数据中心之间创建副本：架构]]”一文。
</div>

## 选择合适的 N 值(n_val)

默认情况下，n_val 的值是 3，即 bucket 中存储的数据会在三个节点中创建副本。为此，集群中至少要有 3 个节点。

如何选择 N 值很大程度上取决于应用程序的需求及数据的类型。如果数据是短期存储的，而且通过应用程序可以很容易的重建，选择较小的 N 值可以提高性能。如果需要保证数据的高可用性，即使节点失效仍能访问，那么提高 N 值可以避免丢失数据。某个时刻最多能接受多少个节点失效呢？根据这个数量来选择一个稍大的值，可以保证这么多节点失效后数据仍可访问。

N 值会影响读（GET）和写（PUT）请求的表现。可以随请求一起提交的参数会受到 N 值的限制。例如，N = 3，那么最大的读请求法定值（R 值）也是 3。如果包含所请求数据的节点下线了，大于可用节点数量的 R 值会导致这次请求失败。

## 设置 N 值(n_val)

要想修改 bucket 的 N 值，可以向这个 bucket 发起 PUT 请求，指定一个新值：

```bash
curl -XPUT -H "Content-Type: application/json" -d '{"props":{"n_val":5}}' http://riak-host:8098/riak/bucket
```

如果 bucket 中已经存有数据，这时不建议修改 N 值。如果一定要修改，特别是要增大，必须强制执行读取修复操作，这样已存的对象和新存入的对象就会自动在所设数量的节点中创建副本。

{{#1.3.0+}}
## Active Anti-Entropy (AAE)

AAE 是一个一直运行的后台程序，比较并修复有分歧、丢失或损坏的副本。[[读取修复|副本#Read-Repair]]只在读取数据时触发，而 AAE 可以保证存储在 Riak 中全部数据的完整性。这个功能特别适合用于存有“冰封数据”（很长时间不会被读取的数据，可能是几年）的集群。AAE 不像 `repair` 命令，无需人工干预，会自动执行，而且从 Riak 1.3 开始默认启用。

Riak 的 AAE 功能建立在哈希树交换的基础上，只交换最少的数据就能发现不同副本之间的差别。这个过程中交换的信息量和副本之间的差异成正比，和副本中存储的数据量无关。一百万个键中如果有 10 个不同的键，和一百亿个键中有 10 个不同的键，这两种情况交换的信息量几乎是相等的。这样不管集群的大小，Riak 就能提供持续的数据保护了。

而且，Riak 中的哈希树持久的存储在硬盘中，而不是存在内存中，这是和其他类似产品的一个关键不同。这样 Riak 只需使用极少的额外内存就能维护十几亿个键，而且节点重启后不会丢失任何反熵信息。Riak 会实时维护哈希树，只要有新的写请求就会更新树，减少了 Riak 检测到丢失或有分歧的副本所用的时间。为了提升保护能力，Riak 会定期（默认为一周一次）从硬盘上存储的键值对数据清理并重建所有的哈希树。因此 Riak 可以检测到硬盘中的过期数据，不管是因为硬盘故障还是硬盘失效导致的。
{{/1.3.0+}}

<a id="Read-Repair"></a>
## 读取修复

读取修复在读取操作成功后执行，即满足法定值时，但并不是所有被请求的副本都会为这个值贡献力量。有两种可能性：

  1. 返回“not found”，表示该节点没有这个对象的副本
  2. 返回一个向量时钟，是这次成功读请求的祖先向量时钟

如果出现这两种情况，Riak 会强制这些节点基于成功的读请求获取的值来更新所存对象。

### 强制执行读取修复

如果增加了 bucket 的 N 值，有可能会读取失败，尤其是当指定的 R 值比之前保存的副本数大时。这时可以强制执行读取修复。

如果读取对象失败了，可以把 R 值设成比之前的副本数小或者相等。例如，如果之前的 N 值是 3，然后增加到 5，读请求时指定的 R 值就要设为 3 或者更小。这样还没有副本的节点会相应“not found”，触发执行读取修复。

## 那么 N=3 到底是什么意思？

N=3 就是说每个数据都会在集群中存有 3 个副本，即 3 个不同的分区（虚拟节点）中会各保存一个数据的副本。**但无法保证这 3 个副本会分别存入 3 个物理节点中**。不过，内建的函数会尝试尽量均匀的分布数据。在某些小概率事件中，Riak 会强制重整分区的所有权，以其获得更好的均布。

如果节点的数量小于 N 值，某些节点上会存有多份副本。例如，N=3，集群中只有 2 个节点，那么其中一个节点可能只有一个副本，而另一个节点则有两个副本。

<a id="Understanding-replication-by-example"></a>
## 通过实例理解副本

为了更好地理解数据是如何在 Riak 中创建副本的，我们来对 <<"my_bucket">>/<<"my_key">> 这个“bucket/键”组合发送一个 PUT 请求。我们会特别关注这次请求的如下两部分：把对象分发到一系列分区中，在分区中排序对象。

### 把对象分发到一系列分区中

  * 假设有 3 个节点
  * 假设每个对象存有 3 个副本（N=3）
  * 假设有 8 个分区（ring_creation_size=8）

**不建议使用这么写的环，这里只做演示用。**

只有 8 个分区的环类似下面这样（为了节省空间，riak_core_ring_manager:get_my_ring/0 的响应被适当截断了）：

```erlang
(dev1@127.0.0.1)3> {ok,Ring} = riak_core_ring_manager:get_my_ring().
[{0,'dev1@127.0.0.1'},
{182687704666362864775460604089535377456991567872, 'dev2@127.0.0.1'},
{365375409332725729550921208179070754913983135744, 'dev3@127.0.0.1'},
{548063113999088594326381812268606132370974703616, 'dev1@127.0.0.1'},
{730750818665451459101842416358141509827966271488, 'dev2@127.0.0.1'},
{913438523331814323877303020447676887284957839360, 'dev3@127.0.0.1'},
{1096126227998177188652763624537212264741949407232, 'dev1@127.0.0.1'},
{1278813932664540053428224228626747642198940975104, 'dev2@127.0.0.1'}]
```

处理这个请求的节点会计算“bucket/键”组合的哈希值：

```erlang
(dev1@127.0.0.1)4> DocIdx = riak_core_util:chash_key({<<"my_bucket">>, <<"my_key">>}).
<<183,28,67,173,80,128,26,94,190,198,65,15,27,243,135,127,121,101,255,96>>
```

DocIdx 哈希是 160 位的整数：

```erlang
(dev1@127.0.0.1)5> <<I:160/integer>> = DocIdx.
<<183,28,67,173,80,128,26,94,190,198,65,15,27,243,135,127,121,101,255,96>>
(dev1@127.0.0.1)6> I.
1045375627425331784151332358177649483819648417632
```

节点会在环中查找计算得到的哈希值，返回一组优先选择的分区：

```erlang
(node1@127.0.0.1)> Preflist = riak_core_ring:preflist(DocIdx, Ring).
[{1096126227998177188652763624537212264741949407232, 'dev1@127.0.0.1'},
{1278813932664540053428224228626747642198940975104, 'dev2@127.0.0.1'},
{0, 'dev1@127.0.0.1'},
{182687704666362864775460604089535377456991567872, 'dev2@127.0.0.1'},
{365375409332725729550921208179070754913983135744, 'dev3@127.0.0.1'},
{548063113999088594326381812268606132370974703616, 'dev1@127.0.0.1'},
{730750818665451459101842416358141509827966271488, 'dev2@127.0.0.1'},
{913438523331814323877303020447676887284957839360, 'dev3@127.0.0.1'}]
```

节点选择前 N 个分区，其他的分区则作为备用，以防选中的分区不可访问：

```erlang
(dev1@127.0.0.1)9> {Targets, Fallbacks} = lists:split(N, Preflist).
{[{1096126227998177188652763624537212264741949407232, 'dev1@127.0.0.1'},
{1278813932664540053428224228626747642198940975104, 'dev2@127.0.0.1'},
{0,'dev1@127.0.0.1'}],
[{182687704666362864775460604089535377456991567872, 'dev2@127.0.0.1'},
{365375409332725729550921208179070754913983135744, 'dev3@127.0.0.1'},
{548063113999088594326381812268606132370974703616, 'dev1@127.0.0.1'},
{730750818665451459101842416358141509827966271488, 'dev2@127.0.0.1'},
{913438523331814323877303020447676887284957839360, 'dev3@127.0.0.1'}]}
```

环返回的分区信息包含分区的标示符和该分区所属的（父）节点：

```erlang
{1096126227998177188652763624537212264741949407232, 'dev1@127.0.0.1'}
```

接受请求的节点向每个父节点发送消息，包含对象和分区的标识符（为了演示，下面的代码是虚构的）：

```erlang
'dev1@127.0.0.1' ! {put, Object, 1096126227998177188652763624537212264741949407232}
'dev2@127.0.0.1' ! {put, Object, 1278813932664540053428224228626747642198940975104}
'dev1@127.0.0.1' ! {put, Object, 0}
```

如果向目标分区存入数据失败了，节点就会把对象发送到后备分区中。发送到后备节点的消息会引用对象，以及之前分区的标识符。例如，如果 `dev2@127.0.0.1` 不可访问，那么接受请求的节点会尝试每一个后备节点。本例中的后备节点如下：

```erlang
{182687704666362864775460604089535377456991567872, 'dev2@127.0.0.1'}
{365375409332725729550921208179070754913983135744, 'dev3@127.0.0.1'}
{548063113999088594326381812268606132370974703616, 'dev1@127.0.0.1'}
```

第二个后备节点是 `dev3@127.0.0.1`。接受请求的节点会向后备节点发送一个消息，包含对象，以及之前分区的标识符。

```erlang
'dev3@127.0.0.1' ! {put, Object, 1278813932664540053428224228626747642198940975104}
```

注意，上面这个消息中的分区标识符和发给 `dev2@127.0.0.1` 消息中的标识符一样，只不过这次接受方是 `dev3@127.0.0.1`。即使 `dev3@127.0.0.1` 不是那个分区的父节点，Riak 还是足够智能，先把数据存在 `dev3@127.0.0.1` 中，只到 `dev2@127.0.0.1` 重新加入集群。

## 处理到各分区的请求

处理到各分区的请求很简单。每个节点上都运行着一个进程（riak_kv_vnode_master），把请求分发到不同的分区进程（riak_kv_vnode）。riak_kv_vnode_master 进程维护着一个分区标识符列表，以及各分区对应的分区进程。如果某个分区标识符没有进程，系统就会派生一个新进程。

riak_kv_vnode_master 进程会平等的对待所有请求，如果需要，即便是当节点处理的请求不会针对其所含分区时，还会派生新的分区进程。如果分区的父节点不可访问，请求会被转发（移交）到后备节点上。后备节点上的 riak_kv_vnode_master 进程会派生一个进程管理这个分区，即使该分区不属于这个后备节点。

每个分区进程在整个生命周期内都会进行“归属测试”（hometest），检查当前节点（node/0)）是不是环中定义的分区父节点。如果检测到分区属于另一（父）节点，会尝试联系那个节点。如果那个节点有响应，就会把当前节点中存储的所有数据移交到那个节点的分区中，然后关闭当前节点。如果那个节点无响应，进程就会继续管理这个分区，等待一段时间后再做检查。分区进程也会做“归属测试”，以获悉环的变动，例如集群中节点的增删。