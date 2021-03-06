/*
 Created on 28/02/2009
 Copyright 2009 Max Howell <max@methylblue.com>
 
 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.
 
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

// Please forgive my n00bness at Cocoa.
// I'd actually appreciate it if you emailed me my mistakes! Thanks.

//TODO when launching, watch the NSTask, and say "Crashed :(" if early exit
//TODO otherwise check status of pid when window becomes key and update button
//TODO remember path that we scanned with defaults controller
//TODO log that stupid exception
//TODO while open auto restart playdar binary if using byo_bin and playdar binary is modified
//TODO defaults should use org.playdar.plist not com.apple.systempreferences.plist
//TODO animate in a link to the demo page when user runs the app and it works
//TODO pipe output to a log file

#import "main.h"
#include <Sparkle/SUUpdater.h>
#include <sys/sysctl.h>


/** returns the pid of the running playdar instance, or 0 if not found */
static pid_t playdar_pid()
{
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    struct kinfo_proc *info;
    size_t N;
    pid_t pid = 0;
    
    if(sysctl(mib, 3, NULL, &N, NULL, 0) < 0)
        return 0; //wrong but unlikely
    if(!(info = NSZoneMalloc(NULL, N)))
        return 0; //wrong but unlikely
    if(sysctl(mib, 3, info, &N, NULL, 0) < 0)
        goto end;

    N = N / sizeof(struct kinfo_proc);
    for(size_t i = 0; i < N; i++)
        if(strcmp(info[i].kp_proc.p_comm, "playdar.smp") == 0)
            { pid = info[i].kp_proc.p_pid; break; }
end:
    NSZoneFree(NULL, info);
    return pid;
}

static inline NSString* fullname()
{
    // being cautious
    NSString* fullname = NSFullUserName();
    return (fullname && [fullname length] > 0) ? fullname : NSUserName();
}



static void kqueue_termination_callback(CFFileDescriptorRef f, CFOptionFlags callBackTypes, void* self)
{
    [(id)self performSelector:@selector(daemonTerminated:) withObject:nil];
}

static inline void kqueue_watch_pid(pid_t pid, id self)
{
    int                     kq;
    struct kevent           changes;
    CFFileDescriptorContext context = { 0, self, NULL, NULL, NULL };
    CFRunLoopSourceRef      rls;

    // Create the kqueue and set it up to watch for SIGCHLD. Use the 
    // new-in-10.5 EV_RECEIPT flag to ensure that we get what we expect.

    kq = kqueue();

    EV_SET(&changes, pid, EVFILT_PROC, EV_ADD | EV_RECEIPT, NOTE_EXIT, 0, NULL);
    (void) kevent(kq, &changes, 1, &changes, 1, NULL);

    // Wrap the kqueue in a CFFileDescriptor (new in Mac OS X 10.5!). Then 
    // create a run-loop source from the CFFileDescriptor and add that to the 
    // runloop.
    
    CFFileDescriptorRef ref;
    ref = CFFileDescriptorCreate(NULL, kq, true, kqueue_termination_callback, &context);
    rls = CFFileDescriptorCreateRunLoopSource(NULL, ref, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, kCFRunLoopDefaultMode);
    CFRelease(rls);
    
    CFFileDescriptorEnableCallBacks(ref, kCFFileDescriptorReadCallBack);
}

#define START_POLL poll_timer = [NSTimer scheduledTimerWithTimeInterval:0.4 target:self selector:@selector(poll:) userInfo:nil repeats:true];


@implementation OrgPlaydarPreferencePane

-(NSString*)playdarDir
{
    return [[[self bundle] resourcePath] stringByAppendingPathComponent:@"playdar"];
}

-(NSString*)startScriptPath
{
    return [[self playdarDir] stringByAppendingPathComponent:@"start.sh"];
}

-(NSString*)playdarctl
{
    return [[self playdarDir] stringByAppendingPathComponent:@"playdarctl"];
}

-(NSString*)playdarConf
{
    return [[self playdarDir] stringByAppendingPathComponent:@"etc/playdar.conf"];
}

-(void)mainViewDidLoad
{   
    [[popup menu] addItem:[NSMenuItem separatorItem]];
    [[[popup menu] addItemWithTitle:@"Other…" action:@selector(onSelect:) keyEquivalent:@""] setTarget:self];

    NSString* home = NSHomeDirectory();
    [self addFolder:[home stringByAppendingPathComponent:@"Music"] setSelected:true];
    [self addFolder:home setSelected:false];

    pid = playdar_pid();
    if(pid){
        // watch the pid for termination
        kqueue_watch_pid(pid, self);
        
        [enable setState:NSOnState];
        [demos setHidden:false];
        [info setHidden:false];
        NSSize size = [[self mainView] frame].size;
        size.height += 20;
        [[self mainView] setFrameSize:size];
    }
    else
        START_POLL;

////// Sparkle
    SUUpdater* updater = [SUUpdater updaterForBundle:[self bundle]];
    [updater resetUpdateCycle];
    [updater setDelegate:self];

    if([[NSApp currentEvent] modifierFlags] & NSAlternateKeyMask)
        [updater checkForUpdates:self];
}

-(void)addFolder:(NSString*)path setSelected:(bool)select
{
    int const index = [[popup menu] numberOfItems]-2;
    NSMenuItem* item = [[popup menu] insertItemWithTitle:path action:nil keyEquivalent:@"" atIndex:index];
    NSImage* image = [[NSWorkspace sharedWorkspace] iconForFile:path];
    [image setSize:NSMakeSize(16, 16)];
    [item setImage:image];
    if(select) [popup selectItemAtIndex:index];
}

-(void)onScan:(id)sender
{
    @try {
        scanner_task = [[NSTask alloc] init];
        [scanner_task setLaunchPath:[self playdarctl]];
        [scanner_task setArguments:[NSArray arrayWithObjects:@"scan", [popup titleOfSelectedItem], nil]];
        [scanner_task launch];

        [scan_spinner startAnimation:self];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(scanComplete:)
                                                     name:NSTaskDidTerminateNotification
                                                   object:scanner_task];
    }
    @catch (NSException* e)
    {
        NSRunCriticalAlertPanel(@"Could not start scan", [e reason], nil, nil, nil);
    }
}

-(void)scanComplete:(NSNotification*)note
{
    [scan_spinner stopAnimation:self];
}

-(void)representHiddenParts
{   
    bool const is_dead = pid == 0;
    
    // eg. if we're hidden, and playdar isn't running, then GUI representation is already correct
    if([info isHidden] != is_dead){    
        [demos setHidden:is_dead];
        [info setHidden:is_dead];  
        
        int const step = is_dead ? -20 : 20;
        NSWindow* w = [popup window];
        NSRect rect = [w frame];
        rect.size.height += step;
        rect.origin.y -= step;
        [w setFrame:rect display:true animate:true];
    }
    if([self isLoginItem] == is_dead)
        [self setLoginItem:!is_dead];
}

-(void)poll:(NSTimer*)_poll_timer
{
    if(pid = playdar_pid()){
        [poll_timer invalidate];
        poll_timer = nil;
        kqueue_watch_pid(pid, self);
        [enable setState:NSOnState];
        [self representHiddenParts];
    }
}
         
-(void)stop
{
    NSTask* task = [[NSTask alloc] init];
    task.launchPath = [self playdarctl];
    task.arguments = [NSArray arrayWithObjects:@"stop", nil];

    [spinner startAnimation:self];
    [task launch];
    [task waitUntilExit];
    
    if (task.terminationStatus == 0) {
        daemon_task = nil;
        [spinner stopAnimation:self];
        return;
    }

    if(daemon_task)
        [daemon_task terminate];
    else if(pid == 0)
        ; // state machine error!
    else if(kill(pid, SIGKILL) == -1 && errno != ESRCH){
        [enable setState:NSOnState];
        NSRunCriticalAlertPanel(@"Could not kill daemon",
                                @"Perhaps you don't have the right permissions?", nil, nil, nil);
    }else{
        // the kqueue event will tell us when the process exits
    }    
}
 
-(void)startInTerminal
{
    daemon_task = [[NSTask alloc] init];
    [daemon_task setLaunchPath:@"/usr/bin/open"];
    [daemon_task setArguments:[NSArray arrayWithObjects:[self startScriptPath], @"-aTerminal", nil]];
    [daemon_task launch];

    pid = -100; //HACK
    [self representHiddenParts];
    [daemon_task waitUntilExit];
    pid = playdar_pid();
    daemon_task = nil;

    if(pid)
        kqueue_watch_pid(pid, self);
    else {
        [enable setState:NSOffState];
        [self representHiddenParts];
    }    
}

-(void)start
{
    daemon_task = [[NSTask alloc] init];
    [daemon_task setLaunchPath:[self startScriptPath]];
    [daemon_task setArguments:[NSArray arrayWithObject:@"-d"]];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(daemonTerminated:)
                                                 name:NSTaskDidTerminateNotification
                                               object:daemon_task];
    [daemon_task launch];
    pid = [daemon_task processIdentifier];    
}

-(void)onEnable:(id)sender
{       
    if ([enable state] == NSOffState) {
        [self stop];
        return;
    }

    [poll_timer invalidate];
    poll_timer=nil;
    
    pid = playdar_pid();
    
    if(!pid){
        @try{
            if(NSAlternateKeyMask & [[NSApp currentEvent] modifierFlags])
                [self startInTerminal];
            else
                [self start];
        }
        @catch(NSException* e)
        {
            NSString* msg = @"The file at “";
            msg = [msg stringByAppendingString:[daemon_task launchPath]];
            msg = [msg stringByAppendingString:@"” could not be executed."];
            
            NSBeginAlertSheet(@"Could not start Playdar",
                              nil, nil, nil,
                              [[self mainView] window],
                              self,
                              nil, nil,
                              nil,
                              msg );
            daemon_task = nil;
        }
    }else{
        // unexpectedly there is already a playdar instance running!
        kqueue_watch_pid(pid, self);
    }
    [self representHiddenParts];
}

-(void)daemonTerminated:(NSNotification*)note
{  
    [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                    name:NSTaskDidTerminateNotification 
                                                  object:daemon_task];
   
    daemon_task = nil;
    pid = 0;
        
    [NSObject cancelPreviousPerformRequestsWithTarget:spinner];
    [spinner stopAnimation:self];
    [enable setState:NSOffState];
    [enable setEnabled:true];
    [self representHiddenParts];
    START_POLL;
}

-(void)setLoginItem:(bool)enabled
{
#if 0
	CFArrayRef loginItems = NULL;
	NSURL *url = [NSURL fileURLWithPath:[self startScriptPath]];
	int existingLoginItemIndex = -1;
	OSStatus err = LIAECopyLoginItems(&loginItems);
	if(err == noErr) {
		NSEnumerator *enumerator = [(NSArray *)loginItems objectEnumerator];
		NSDictionary *loginItemDict;
        
		while((loginItemDict = [enumerator nextObject])) {
			if([[loginItemDict objectForKey:(NSString *)kLIAEURL] isEqual:url]) {
				existingLoginItemIndex = [(NSArray *)loginItems indexOfObjectIdenticalTo:loginItemDict];
				break;
			}
		}
	}
    
	if(enabled && (existingLoginItemIndex == -1))
		LIAEAddURLAtEnd((CFURLRef)url, false);
	else if(!enabled && (existingLoginItemIndex != -1))
		LIAERemove(existingLoginItemIndex);
    
	if(loginItems)
		CFRelease(loginItems);
#endif
}

-(bool)isLoginItem
{
#if 0
    Boolean foundIt = false;
    CFArrayRef loginItems = NULL;
    CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)[self startScriptPath], kCFURLPOSIXPathStyle, false);
    OSStatus err = LIAECopyLoginItems(&loginItems);
    if(err == noErr) {
        for(CFIndex i=0, N=CFArrayGetCount(loginItems); i<N; ++i) {
            CFDictionaryRef loginItem = CFArrayGetValueAtIndex(loginItems, i);
            foundIt = CFEqual(CFDictionaryGetValue(loginItem, kLIAEURL), url);
            if(foundIt) break;
        }
        CFRelease(loginItems);
    }
    CFRelease(url);  
    return foundIt;
#else
    return true;
#endif
}

////// Directory selector
-(void)onSelect:(id)sender
{
    // return if not the Select... item
    if([popup indexOfSelectedItem] != [popup numberOfItems]-1) return;
    
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:NO];
    [panel setCanChooseDirectories:YES];
    [panel beginSheetForDirectory:nil 
                             file:nil 
                   modalForWindow:[[self mainView] window]
                    modalDelegate:self
                   didEndSelector:@selector(openPanelDidEnd:returnCode:contextInfo:)
                      contextInfo:nil];
}

-(void)openPanelDidEnd:(NSOpenPanel*)panel
            returnCode:(int)returnCode
           contextInfo:(void*)contextInfo 
{
    if(returnCode == NSOKButton) {
        [self addFolder:[panel filename] setSelected:true];
    } else
        [popup selectItemAtIndex:0];
}
////// Directory selector

-(IBAction)onHelp:(id)sender
{
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://methylblue.com/playdar/faq.php"]];
}

-(IBAction)onAdvanced:(id)sender
{
    [NSApp beginSheet:advanced_window
       modalForWindow:[[self mainView] window]
        modalDelegate:self
       didEndSelector:nil
          contextInfo:nil];
}

-(IBAction)onCloseAdvanced:(id)sender
{
#if 0
    if([[NSUserDefaults standardUserDefaults] boolForKey:MBHomemade]){
        NSString* path = [self bin]; //use path that script eventually uses
        if([[NSFileManager defaultManager] isExecutableFileAtPath:path] == false){
            NSRunAlertPanel( @"Bad path", [path stringByAppendingString:@" isn't playdar"], nil, nil, nil );
            return;
        }
    }
#endif

    [advanced_window orderOut:nil];
    [NSApp endSheet:advanced_window];
}

-(IBAction)onEditConfigFile:(id)sender;
{
    #define OPEN(x) [[NSWorkspace sharedWorkspace] openFile:[self playdarConf] withApplication:x]
    if (!OPEN(@"TextMate")) OPEN(@"TextEdit");
}

-(IBAction)onDemos:(id)sender
{
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://playdar.org/demos/"]];
}

-(IBAction)onViewStatus:(id)sender
{
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://localhost:60210"]];
}

@end


@implementation OrgPlaydarPreferencePane(SUUpdaterDelegateInformalProtocol)

-(void)updaterWillRelaunchApplication:(SUUpdater*)updater
{
    if(pid) kill(pid, SIGKILL);
}

-(NSString*)pathToRelaunchForUpdater:(SUUpdater*)updater
{
    return [[NSBundle mainBundle] bundlePath];
}

@end
