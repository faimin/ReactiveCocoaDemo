//
//  PushController.m
//  ReactiveCocoaDemo
//
//  Created by Zero.D.Saber on 15/12/24.
//  Copyright © 2015年 zd. All rights reserved.
//

#import "PushController.h"
#import "RACSignal+Extend.h"

@interface PushController ()
@property (weak, nonatomic) IBOutlet UIButton *okButton;
@property (weak, nonatomic) IBOutlet UIButton *testButton;
@end

@implementation PushController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    
    [self notification];
    
    self.okButton.rac_command = self.command;
    
    // 防止按钮多次点击
    [self filterButtonAction];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)notification
{
    // 必须要添加takeUntil来控制去release信号，否则会出现内存泄露
    [[[[NSNotificationCenter defaultCenter] rac_addObserverForName:kNotification object:nil] takeUntil:self.rac_willDeallocSignal] subscribeNext:^(NSNotification *x) {
        NSLog(@"%@", x.object);
    }];
}

- (void)filterButtonAction {
    
    RACSignal *buttonSignal_ = [self.okButton rac_signalForControlEvents:UIControlEventTouchUpInside];
    [[buttonSignal_ filterEventWithInterval:1.5] subscribeNext:^(id x) {
        NSLog(@"XXXXXXXXX");
    }];
    
    
    [[[self.testButton rac_signalForControlEvents:UIControlEventTouchUpInside] filterEventWithInterval:2] subscribeNext:^(id x) {
        NSLog(@"************");
    }];
    
    return;
    
    RACSignal *buttonSignal = [[self.okButton rac_signalForControlEvents:UIControlEventTouchUpInside] replayLast];
    //**方案1
    [[[buttonSignal take:1] concat:[[buttonSignal skip:1] throttle:0.3]] subscribeNext:^(id x) {
        NSLog(@"方案1");
    }];
    
    //**方案2
    NSTimeInterval margin = 3;//时间间隔
    __block double lastTime = 0;
    [[[buttonSignal take:1] concat:[[buttonSignal skip:1] filter:^BOOL(id value) {
        double currentTime = CFAbsoluteTimeGetCurrent();
        if (lastTime > 0 && currentTime - lastTime > margin) {
            lastTime = CFAbsoluteTimeGetCurrent();
            return YES;
        }
        return NO;
    }]] subscribeNext:^(id x) {
        NSLog(@"方案2");
    }];
    
    //**方案3
    [[buttonSignal filter:^BOOL(id value) {
        if (lastTime == 0) {
            lastTime = CFAbsoluteTimeGetCurrent();
            return YES;
        } else {
            if (CFAbsoluteTimeGetCurrent() - lastTime > margin) {
                lastTime = CFAbsoluteTimeGetCurrent();
                return YES;
            }
            return NO;
        }
    }] subscribeNext:^(id  _Nullable x) {
        NSLog(@"方案3");
    }];
}

/*
#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
}
*/

@end








