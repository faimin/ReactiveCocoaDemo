### 解读ReactiveCocoa中几个函数

#### 一、bind、flattenMap、map以及flatten

> 冷信号与热信号：
> 
> 1. Hot Observable是主动的，尽管你并没有订阅事件，但是它会时刻推送，就像鼠标移动；而Cold Observable是被动的，只有当你订阅的时候，它才会发布消息。
>    
>  2. Hot Observable可以有多个订阅者，是一对多，集合可以与订阅者共享信息；而Cold Observable只能一对一，当有不同的订阅者，消息是重新完整发送。
>  3. 冷信号可以理解为`点播`，每次订阅都从头开始；热信号可以理解为`直播`，订阅时从当前的状态开始；

---

> * `map`和`flatten`是基于`flattenMap`,而`flattenMap`是基于`bind:`,所以在此之前先来看看`bind`函数。
 
##### 1. bind:
* 具体来看源码（为方便理解，去掉了源代码中`RACDisposable`, `@synchronized`, `@autoreleasepool`相关代码)。当新信号`N`被外部订阅时，会进入信号`N`的`didSubscribeBlock` (1)，之后订阅原信号`O` (2)，当原信号`O`有值输出后就用`bind`函数传入的`bindBlock`将其变换成中间信号`M` (3), 并马上对其进行订阅(4)，最后将中间信号`M`的输出作为新信号`N`的输出 (5)。即：当新生成的信号被订阅时，源信号也会立即被订阅。

```objectivec
- (RACSignal *)bind:(RACStreamBindBlock (^)(void))block {
    return [RACSignal createSignal:^(id<RACSubscriber> subscriber) { // (1)

        RACStreamBindBlock bindingBlock = block(); // (MARK:此处执行block回调,生成一个bindingBlock)

        [self subscribeNext:^(id x) {  // (2)
            BOOL stop = NO;
            id middleSignal = bindingBlock(x, &stop);  // (3) map与flatten结果不同，问题就出在这里

            if (middleSignal != nil) {
                RACDisposable *disposable = [middleSignal subscribeNext:^(id x) { // (4)
                    [subscriber sendNext:x];  // (5)
                } error:^(NSError *error) {
                    [subscriber sendError:error];
                } completed:^{
                    [subscriber sendCompleted];
                }];
            }
        } error:^(NSError *error) {
            [subscriber sendError:error];
        } completed:^{
            [subscriber sendCompleted];
        }];

        return nil
    }];
}
```

##### 2. flattenMap:
`flattenMap`其实就是对`bind:`方法进行了一些安全检查，它最终返回的是`bindBlock`执行后生成的那个中间`signal`又被订阅后传递出的值的信号，而`map`方法返回的是`bindBlock`的执行结果生成的那个信号，没有再加工处理（即被订阅，再发送值）

```objectivec
- (instancetype)flattenMap:(RACStream * (^)(id value))block {
    Class class = self.class;

    return [[self bind:^{
        /// @return 返回的是RACStreamBindBlock
        /// @discussion
        ///
        /// 跟`bind：`方法中的代码对应起来如下：
        /// BOOL stop = NO;
        /// id middleSignal = bindingBlock(x, &stop);
        ///
        /// 与上面`bind:`函数中的(3)对应起来,
        /// 可以看出bindBlock中的x是原信号被subscribe后传出的值，即对应下面的value
        /// 也即flattenMap中的 block执行后传出的值，
        /// 即上面的(RACStream * (^ block)(id value))中的value
        /// flattenMap:后的那个block其实与bind:后的block基本是一样的，参数都是原信号发出的值，返回值都是RACStream，差别就是一个bool参数，所以说，flattenMap其实就是对bind方法进行了一些安全检查
        /// 综上所述：*flattenMap方法中传进来的那个block参数值就是原信号被订阅后发送的值*
        return ^(id value, BOOL *stop) {
            // 下面这个value并不是flattenMap后面block中的那个value，而是(就近原则)原信号中的值；flattenMap后面那个block中的value的值是原信号发出的值被转换为中间信号后，又被订阅后发出去的值，这里要区分开；
            id stream = block(value) ?: [class empty];
            NSCAssert([stream isKindOfClass:RACStream.class], @"Value returned from -flattenMap: is not a stream: %@", stream);

            return stream;
        };
    }] setNameWithFormat:@"[%@] -flattenMap:", self.name];
}
```

##### 3. map:
`map`: 下面是`map`方法的源码，可以看出，`map`只是对`flattenMap`传出的`vaue`（即原信号传出的值）进行了`mapBlock`操作，并没有再进行订阅操作，即并不像`bind：`一样再次对原信号进行`bindBlock`后生成的中间信号进行订阅。

```objectivec
- (instancetype)map:(id (^)(id value))block {
    NSCParameterAssert(block != nil);

    Class class = self.class;

    return [[self flattenMap:^(id value) {
        return [class return:block(value)];
    }] setNameWithFormat:@"[%@] -map:", self.name];
}
```

##### 4. flatten:
`flatten`: 该操作主要作用于信号的信号。原信号`O`作为信号的信号，在被订阅时输出的数据必然也是个信号`(signalValue)`，这往往不是我们想要的。当我们执行`[O flatten]`操作时，因为`flatten`内部调用了`flattenMap` (1)，`flattenMap`里对应的中间信号就是原信号`O`输出的`signalValue` (2)。按照之前分析的经验，在`flattenMap`操作中新信号`N`输出的结果就是各中间信号`M`输出的集合。因此在`flatten`操作中新信号`N`被订阅时输出的值就是原信号`O`的各个子信号输出值的集合。

```objectivec
- (instancetype)flatten
{
    return [self flattenMap:^(RACSignal *signalValue) { // (1)
            /// 返回值作为bind:中的中间信号
        return signalValue; // (2)
    };
}
```

##### 5. **小结：**
以前一直不理解`flatten`与`map`之间的区别，然后经过不断在源码中打断点，一步步跟代码，终于是明白了：
`flatten`和`map`后面的block返回结果其实最终都会变为`bind:`方法中的中间信号，但是`flatten:`的`block`是直接把原信号发出的值返回来作为中间信号的，所以中间信号被订阅，其实就是原信号发出的值又被订阅，这也就是`flatten:`能拿到信号中的信号中的值的原因。
而`map:`后面的block是把原信号发出的值加工处理了的，又生成了一个新的信号，即`map:`方法`block`返回的中间信号已经不是原来的信号中的信号了，而是把原信号发出的值作为它的包含值的一个新的信号，它被订阅时，发送的是原信号发出的那个值，这就是`map`拿不到原信号中的信号的原因。
说白了就是`flatten:`操作的始终是原来的信号，而`map:`会生成一个包含原信号发送值的新信号。

---

#### 二、multicast:
简单分析一下 `- (RACMulticastConnection *)multicast:(RACSubject *)subject;`方法：

* 1、当 `RACSignal` 类的实例调用 `- (RACMulticastConnection *)multicast:(RACSubject *)subject` 时，以 `self` 和 `subject` 作为构造参数创建一个 `RACMulticastConnection` 实例。
* 2、`RACMulticastConnection` 构造的时候，保存 `source` 和 `subject` 作为成员变量，创建一个 `RACSerialDisposable` 对象，用于取消订阅。
* 3、当 `RACMulticastConnection` 类的实例调用 `- (RACDisposable *)connect` 这个方法的时候，判断是否是第一次。如果是的话 用 `_signal` 这个成员变量（RACSubject类型）来订阅 `sourceSignal`， 之后返回 `self.serialDisposable`，否则直接返回 `self.serialDisposable` 。
* 4、`RACMulticastConnection` 的 `signal` 只读属性，就是一个热信号，订阅这个热信号就避免了各种副作用的问题。它会在 `- (RACDisposable *)connect` 第一次调用后，根据 `sourceSignal` 的订阅结果来传递事件。
* 5、想要确保第一次订阅就能成功订阅 `sourceSignal` ，可以使用 `- (RACSignal *)autoconnect` 这个方法，它保证了第一个订阅者触发 `sourceSignal` 的订阅，也保证了当返回的信号所有订阅者都关闭连接后 `sourceSignal` 被正确关闭连接。
* 6、这里面订阅 `sourceSignal` 是重点，`_signal`是一个`RACSubject`类型，它里面维护着一个可变数组，每当它被订阅时，会把所有的**订阅者**保存到这个数组中。当`connection.signal`（即`_signal`）被订阅时，其实是`_signal`被订阅了。由于`_signal`是`RACSubject`类型对象，且`_signal`也是信号，它里面重写了订阅方法，所以会执行它自己的`subscribe:`方法，执行此方法之前订阅者参数是`RACSubscriber`类型，但是在这个subscribe方法中，初始化了一个`RACPassthroughSubscriber`实例对象，使它作为新的订阅者（其实就是对订阅者进行了一层包装），并把它存入了`subject`维护的那个订阅者数组里（原来的`订阅者`和`信号`被`RACPassthroughSubscriber`实例保存了），所以数组中最终保存的是`RACPassthroughSubscriber`类型的订阅者，然后它发送消息的时候调的还是它持有的`subject`对象进行发送消息。
* 7、当`RACMulticastConnection`调用`connect`方法时，源信号`sourceSignal`被`_signal`订阅，即执行`[sourceSignal subscribe:subject]`方法，然后执行订阅`subscribeNext:`block回调，在回调中执行`sendNext:`，由于订阅者是`RACSubject`类型的实例对象，它里面也会执行`sendNext:`方法，此方法中会遍历它的数组中的订阅者依次发送消息。
* 8、`connect`时订阅者是`RACSubject`发送的`sendNext:`，subject会拿到它那个订阅者数组遍历，取出其中的`RACPassthroughSubscriber`对象，然后用`RACPassthroughSubscriber`对象中的真实的订阅者去发送数据。

---

#### 三、RACCommand

不废话，直接上源码:

```objectivec
- (id)initWithEnabled:(RACSignal *)enabledSignal signalBlock:(RACSignal * (^)(id input))signalBlock {
    NSCParameterAssert(signalBlock != nil);

    self = [super init];
    if (self == nil) return nil;

    _activeExecutionSignals = [[NSMutableArray alloc] init];
    _signalBlock = [signalBlock copy];

    // 监听`activeExecutionSignals`数组
    RACSignal *newActiveExecutionSignals = [[[[[self
        rac_valuesAndChangesForKeyPath:@keypath(self.activeExecutionSignals) options:NSKeyValueObservingOptionNew observer:nil]
        reduceEach:^(id _, NSDictionary *change) {
            NSArray *signals = change[NSKeyValueChangeNewKey];
            if (signals == nil) return [RACSignal empty];
            // 把数组转换为信号发送出去
            return [signals.rac_sequence signalWithScheduler:RACScheduler.immediateScheduler];
        }]
        concat]            // 把各个信号中的信号连接起来
        publish]            // 广播出去，可以被多个订阅者订阅
        autoconnect];    // 有订阅了再发送广播

    // 把上面的信号`map`一下,当出现错误的时候转换成`empty`空信号,并在主线程上传递
    _executionSignals = [[[newActiveExecutionSignals
        map:^(RACSignal *signal) {
            return [signal catchTo:[RACSignal empty]];
        }]
        deliverOn:RACScheduler.mainThreadScheduler]
        setNameWithFormat:@"%@ -executionSignals", self];

    // 先通过`ignoreValues`方法屏蔽掉`sendNext:`的结果，只保留`sendError:`和`sendCompleted`结果，然后再通过`catch:`方法拿到所有的`sendError:`结果，发送给订阅者。
    // 此处用的是`flattenMap`，可以直接获取到错误信息。
    RACMulticastConnection *errorsConnection = [[[newActiveExecutionSignals
        flattenMap:^(RACSignal *signal) {
            return [[signal
                ignoreValues]
                catch:^(NSError *error) {
                    return [RACSignal return:error];
                }];
        }]
        deliverOn:RACScheduler.mainThreadScheduler]
        publish];

    _errors = [errorsConnection.signal setNameWithFormat:@"%@ -errors", self];
    [errorsConnection connect];

    // 根据执行信号的数量判断`RACCommand`当前是否正在执行
    RACSignal *immediateExecuting = [RACObserve(self, activeExecutionSignals) map:^(NSArray *activeSignals) {
        return @(activeSignals.count > 0);
    }];

    // 是否正在执行
    _executing = [[[[[immediateExecuting
        deliverOn:RACScheduler.mainThreadScheduler]
        // This is useful before the first value arrives on the main thread.
        startWith:@NO]
        distinctUntilChanged]
        replayLast]
        setNameWithFormat:@"%@ -executing", self];

    // 如果允许并发执行，返回`YES`，否则反转`immediateExecuting`信号的结果
    RACSignal *moreExecutionsAllowed = [RACSignal
        if:RACObserve(self, allowsConcurrentExecution)
        then:[RACSignal return:@YES]
        else:[immediateExecuting not]];

    if (enabledSignal == nil) {
        enabledSignal = [RACSignal return:@YES];
    } else {
        enabledSignal = [[[enabledSignal
            startWith:@YES]
            takeUntil:self.rac_willDeallocSignal]
            replayLast];
    }

    _immediateEnabled = [[RACSignal
        combineLatest:@[ enabledSignal, moreExecutionsAllowed ]]
        and];

    _enabled = [[[[[self.immediateEnabled
        take:1]
        concat:[[self.immediateEnabled skip:1] deliverOn:RACScheduler.mainThreadScheduler]]
        distinctUntilChanged]
        replayLast]
        setNameWithFormat:@"%@ -enabled", self];

    return self;
}

// 使用时，我们通常会去生成一个RACCommand对象，并传入一个返回signal对象的block。每次RACCommand execute 执行操作时，都会通过传入的这个signal block生成一个执行信号E (1)，并将该信号添加到RACCommand内部信号数组activeExecutionSignals中 (2)，同时将信号E由冷信号转成热信号(3)，最后订阅该热信号(4)，并将其返回(5)。
- (RACSignal *)execute:(id)input { 
    RACSignal *signal = self.signalBlock(input); //（1）
    RACMulticastConnection *connection = [[signal subscribeOn:RACScheduler.mainThreadScheduler] multicast:[RACReplaySubject subject]]; // (3)

    @weakify(self);
    [self addActiveExecutionSignal:connection.signal]; // (2)

    [connection.signal subscribeError:^(NSError *error) {
        @strongify(self);
        [self removeActiveExecutionSignal:connection.signal];
    } completed:^{
        @strongify(self);
        [self removeActiveExecutionSignal:connection.signal];
    }];

    [connection connect]; // (4)

    return [connection.signal]; // (5)
}
```

#### 四、RAC自释放
`RAC`的自释放其实是`hook`了`dealloc`方法，但是他只是`hook`了当前类的`dealloc`方法，并没有`hook`掉所有对象的`dealloc`方法(比如`NSObject`的`dealloc`方法)，主要实现代码如下：

```objectivec
static void swizzleDeallocIfNeeded(Class classToSwizzle) {
	@synchronized (swizzledClasses()) {
	    // 被hook过的类会加入到这个单例集合中，如果当前类被hook过直接返回，避免重复hook导致问题
		NSString *className = NSStringFromClass(classToSwizzle);
		if ([swizzledClasses() containsObject:className]) return;
     
        // 获取 dealloc 方法
		SEL deallocSelector = sel_registerName("dealloc");
        
        // 创建 `orignalDealloc` 函数指针，为了保存 `dealloc` 的原始实现，注意这里是__block的，后面才会真正赋值
		__block void (*originalDealloc)(__unsafe_unretained id, SEL) = NULL;

        // 创建一个新的自定义的 `newDealloc` 函数
		id newDealloc = ^(__unsafe_unretained id self) {
		    // 获取当前对象持有的 `compoundDisposable` ，然后调用释放的方法
		    // 这个方法最终会触发 `rac_willDeallocSignal` 
			RACCompoundDisposable *compoundDisposable = objc_getAssociatedObject(self, RACObjectCompoundDisposable);
			[compoundDisposable dispose];
        
            // 说明当前对象没有实现dealloc方法，此种情况下直接调用 `[super dealloc]` 方法
			if (originalDealloc == NULL) {   
			   // 构造super对象
				struct objc_super superInfo = {
					.receiver = self,
					.super_class = class_getSuperclass(classToSwizzle)
				};

				void (*msgSend)(struct objc_super *, SEL) = (__typeof__(msgSend))objc_msgSendSuper;
				msgSend(&superInfo, deallocSelector);
			} 
			// 当前对象实现了`dealloc`方法，所以直接调用当前对象自己的`dealloc`方法，即 `[self dealloc]`
			else {                         
				originalDealloc(self, deallocSelector);
			}
		};
		
		// 获取 `newDealloc` 函数（`IMP` 其实质就是 `C` 函数）
		IMP newDeallocIMP = imp_implementationWithBlock(newDealloc);
		
		// 给当前类添加`dealloc`方法，
		// 如果添加成功，说明当前类没有覆写`dealloc`，
		// 否则说明，当前类覆写了`dealloc`方法，比如用了`kvo`的时候需要在`dealloc`方法中移除观察者
		// 如果能够进入 if 判断里说明当前类实现了`dealloc`方法
		if (!class_addMethod(classToSwizzle, deallocSelector, newDeallocIMP, "v@:")) {

			// 能够执行到这里，说明当前类实现了获取当前类的 `dealloc` Method
			Method deallocMethod = class_getInstanceMethod(classToSwizzle, deallocSelector);
			
			// 替换`dealloc`方法的实现之前，先保存原来的实现，以防正在替换时`dealloc`被调用
			originalDealloc = (__typeof__(originalDealloc))method_getImplementation(deallocMethod);
			
			// We need to store original implementation again, in case it just changed.
			// 把`dealloc`方法替换为上面新的实现，如果替换成功会返回原来的实现
			originalDealloc = (__typeof__(originalDealloc))method_setImplementation(deallocMethod, newDeallocIMP);
		}
      
        // 把当前类名添加到集合中
		[swizzledClasses() addObject:className];
	}
}
```

#### 五、其他：
下面介绍几个函数

```objectivec
- (void)dispose {
	void (^disposeBlock)(void) = NULL;

	while (YES) {
		void *blockPtr = _disposeBlock;
		// 比较blockPtr是否与_disposeBlock指针指向的内存位置的值相匹配，如果匹配，则将_disposeBlock指针指向的内存位置设置为中间的NULL；
		// 整个函数的返回值就是交换是否成功的BOOL值。
		// 当前这个while循环里只有当OSAtomicCompareAndSwapPtrBarrier返回值为YES时才能退出循环，即&_disposeBlock被置为了NULL，避免了野指针问题
		if (OSAtomicCompareAndSwapPtrBarrier(blockPtr, NULL, &_disposeBlock)) {
			if (blockPtr != (__bridge void *)self) {
				disposeBlock = CFBridgingRelease(blockPtr);
			}

			break;
		}
	}

	if (disposeBlock != nil) disposeBlock();
}
```

```objectivec
// 以下是对`allowsConcurrentExecution`属性的处理方法，利用了属性的原子性，防止资源竞争，值得学习
@property (atomic, assign) BOOL allowsConcurrentExecution;
@property (atomic, copy, readonly) NSArray *activeExecutionSignals;

{
    // The mutable array backing `activeExecutionSignals`.
    //
    // This should only be used while synchronized on `self`.
    NSMutableArray *_activeExecutionSignals;

    // Atomic backing variable for `allowsConcurrentExecution`.
    volatile uint32_t _allowsConcurrentExecution;
}


//============================================================

- (BOOL)allowsConcurrentExecution {
    return _allowsConcurrentExecution != 0;
}

- (void)setAllowsConcurrentExecution:(BOOL)allowed {
    [self willChangeValueForKey:@keypath(self.allowsConcurrentExecution)];

    if (allowed) {
        // 以下函数类似于 `||`  
        // 只要前者和后者有一个为真，那么后者就为真；即：不管`_allowsConcurrentExecution`是否等于1，它最终都会变为`1`，因为前者是1；
        OSAtomicOr32Barrier(1, &_allowsConcurrentExecution);
    } else {
        // 以下函数类似于 `&&`  
        // 前后二者必须都为真，后者才会变为真；即：不管`_allowsConcurrentExecution`等于0还是1，它最终都会变为`0`，因为前者是0
        OSAtomicAnd32Barrier(0, &_allowsConcurrentExecution);
    }
    // 手动调用KVO，通知监听者 `allowsConcurrentExecution`属性改变了
    [self didChangeValueForKey:@keypath(self.allowsConcurrentExecution)];
}

//========================数组属性================================
- (NSArray *)activeExecutionSignals {
    @synchronized (self) {
        return [_activeExecutionSignals copy];
    }
}

- (void)addActiveExecutionSignal:(RACSignal *)signal {
    @synchronized (self) {
        NSIndexSet *indexes = [NSIndexSet indexSetWithIndex:_activeExecutionSignals.count];
        [self willChange:NSKeyValueChangeInsertion valuesAtIndexes:indexes forKey:@keypath(self.activeExecutionSignals)];
        [_activeExecutionSignals addObject:signal];
        [self didChange:NSKeyValueChangeInsertion valuesAtIndexes:indexes forKey:@keypath(self.activeExecutionSignals)];
    }
}

- (void)removeActiveExecutionSignal:(RACSignal *)signal {
    @synchronized (self) {
        // 从当前数组中获取到要移除的对象的indexSets，如果不存在直接返回
        NSIndexSet *indexes = [_activeExecutionSignals indexesOfObjectsPassingTest:^ BOOL (RACSignal *obj, NSUInteger index, BOOL *stop) {
            return obj == signal;
        }];

        if (indexes.count == 0) return;
        // 手动调用KVO，通知监听者 `activeExecutionSignals` 数组的改变
        [self willChange:NSKeyValueChangeRemoval valuesAtIndexes:indexes forKey:@keypath(self.activeExecutionSignals)];
        [_activeExecutionSignals removeObjectsAtIndexes:indexes];
        [self didChange:NSKeyValueChangeRemoval valuesAtIndexes:indexes forKey:@keypath(self.activeExecutionSignals)];
    }
}
```

#### 附录：

##### 附1：部分函数的图表解释

> ![CombineLatest](http://img0.tuicool.com/QbyMjyR.png)
> ![Zip](http://img2.tuicool.com/JBrMn2r.png)
> ![操作结果](http://img0.tuicool.com/Nr2AriV.png)
> ![Merge](http://img1.tuicool.com/U3Mzym3.png)
> ![Concat](http://img0.tuicool.com/faIv6bu.png)

##### 附2：`ReactiveCocoa`和`RxSwift` API图
> 引用自[FRPCheatSheeta](https://github.com/aiqiuqiu/FRPCheatSheeta)

**1. ReactiveCocoa-ObjC**
![ReactiveCocoa-Objc](http://ww1.sinaimg.cn/large/006tNbRwjw1f69ss3l0y4j31jf1cpwtm.jpg)

**2. ReactiveCocoa-Swift**
![ReactiveCocoaV4.x-Swift.png](http://ww4.sinaimg.cn/large/006tNbRwjw1f69u9n630vj31kw10nk1g.jpg)

**3. RxSwift**
![RXSwift.png](http://ww2.sinaimg.cn/large/006tNbRwjw1f69u2fugtjj317k1n1tis.jpg)

#### 参考:
+ [RAC核心元素与信号流](http://www.jianshu.com/p/d262f2c55fbe) 
+ [细说ReactiveCocoa的冷信号与热信号（三）：怎么处理冷信号与热信号](http://tech.meituan.com/talk-about-reactivecocoas-cold-signal-and-hot-signal-part-3.html) 
+ [Halfrost's Field分析ReactiveCocoa的系列文章](http://www.tuicool.com/sites/NRbMbqa)
+ [Reactive Cocoa中的@weakify、@strongify的实现](http://www.tuicool.com/articles/QJrqeam)
