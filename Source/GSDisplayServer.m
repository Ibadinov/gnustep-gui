/** <title>GSDisplayServer</title>

   <abstract>Abstract display server class.</abstract>

   Copyright (C) 2002 Free Software Foundation, Inc.

   Author: Adam Fedor <fedor@gnu.org>
   Date: Mar 2002
   
   This file is part of the GNU Objective C User interface library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Library General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.
   
   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.
   
   You should have received a copy of the GNU Library General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111 USA.
   */

#include <Foundation/NSArray.h>
#include <Foundation/NSDictionary.h>
#include <Foundation/NSData.h>
#include <Foundation/NSLock.h>
#include <Foundation/NSRunLoop.h>
#include <Foundation/NSThread.h>

#include "AppKit/NSEvent.h"
#include "AppKit/NSImage.h"
#include "AppKit/NSWindow.h"
#include "GNUstepGUI/GSDisplayServer.h"

#include "GSSlideView.h"

/* Display attributes */
NSString * GSDisplayName = @"DisplayName";
NSString * GSDisplayNumber = @"DisplayNumber";
NSString * GSScreenNumber = @"ScreenNumber";

/* The memory zone where all server objects are allocated from (Contexts
   are also allocated from this zone) */
static NSZone *_globalGSZone = NULL;

/* The current concrete class */
static Class defaultServerClass = NULL;

/* Maps windows to a server */
static NSMapTable *windowmaps = NULL;

/* Lock for use when creating contexts */
static NSRecursiveLock  *serverLock = nil;

static NSString *NSCurrentServerThreadKey;

/** Returns the GSDisplayServer that created the interal
    representation for window. If the internal representation has not
    yet been created (for instance, if the window is deferred), it
    returns the current server */
GSDisplayServer *
GSServerForWindow(NSWindow *window)
{
  int num;
  if (windowmaps == NULL)
    {
      NSLog(@"GSServerForWindow: No window server");
      return nil;
    }

  num = [window windowNumber];
  if (num == 0)
    {
      /* Backend window hasn't been initialized yet, assume current server. */
      return GSCurrentServer();
    }
  return NSMapGet(windowmaps, (void *)num);
}

/** Returns the current GSDisplayServer */
GSDisplayServer *
GSCurrentServer(void)
{
  NSMutableDictionary *dict = [[NSThread currentThread] threadDictionary];

  return (GSDisplayServer*) [dict objectForKey: NSCurrentServerThreadKey];
}

/**
  <unit>
  <heading>GSDisplayServer</heading>

  <p>This is an abstract class which provides a framework for a device
  independant window server. A window server handles the very basic control
  of the computer display and input. This includes basic window
  creation and handling, event handling, cursors, and providing
  miscellaneous information about the display.
  </p>
  
  <p>Typically a backend library will provide a concrete subclass
  which implements the device specific methods described below.
  </p>

  <p>In almost all cases, you should not call these methods directly
  in an application. You should use the equivalent methods available
  elsewhere in the library (e.g. NSWindow, NSScreen, etc).
  </p>

  </unit> */
  
@implementation GSDisplayServer

+ (void) initialize
{
  if (serverLock == nil)
    {
      [gnustep_global_lock lock];
      if (serverLock == nil)
	{
	  serverLock = [NSRecursiveLock new];
	  _globalGSZone = NSDefaultMallocZone();
	  defaultServerClass = [GSDisplayServer class];
	  NSCurrentServerThreadKey  = @"NSCurrentServerThreadKey";
	}
      [gnustep_global_lock unlock];
    }
}

/** Set the concrete subclass that will provide the device dependant
    implementation.
*/
+ (void) setDefaultServerClass: (Class)aClass
{
  defaultServerClass = aClass;
}

/** 
    <p>Create a window server with attributes, which contains key/value
    pairs which describe the specifics of how the window server is to
    be initialized. Typically these values are specific to the
    concrete implementation. The current set of attributes that can be
    used with GSDisplayServer is.
   </p>
   <list>
     <item>GSDisplayName</item>
     <item>GSDisplayNumber</item>
     <item>GSScreenNumber</item>
   </list>
   <p>
   GSDisplayName is window server specific and shouldn't be used when
   creating a GSDisplayServer (although you can retrieve the value with
   the -attributes method). On X-Windows the value might be set to something
   like "host:d.s" where host is the host name, d is the display number and
   s is the screen number. GSDisplayNumber indicates the number of the
   display to open. GSScreenNumber indicates the number of the screen to
   display on. If not explicitly set, these attributes may be taked from
   environment variables or from other operating specific information.
   </p>
    <p>In almost all applications one would only create a
    single instance of a window server. Although it is possible, it is
    unlikely that you would need more than one window server (and you
    would have to be very careful how you handled window creation and
    events in this case).</p>
*/
+ (GSDisplayServer *) serverWithAttributes: (NSDictionary *)attributes
{
  GSDisplayServer *server;

  if (windowmaps == NULL)
    {
      windowmaps = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks,
				    NSNonOwnedPointerMapValueCallBacks, 20);
    }

  if (self == [GSDisplayServer class])
    {
      server = [[defaultServerClass allocWithZone: _globalGSZone]
	       initWithAttributes: attributes];
    }
  else
    server = [[self allocWithZone: _globalGSZone] 
	       initWithAttributes: attributes];
 
  return AUTORELEASE(server);
}

/** 
    Sets the current server that will be handling windows, events,
    etc. This method must be called after a window server is created
    in order to make it available to the rest of the GUI library
*/
+ (void) setCurrentServer: (GSDisplayServer *)server
{
  NSMutableDictionary *dict = [[NSThread currentThread] threadDictionary];
  if (server)
    [dict setObject: server forKey: NSCurrentServerThreadKey];
  else
    [dict removeObjectForKey: NSCurrentServerThreadKey];
}

/** <init />
    Initializes the server. This typically causes the receiver to 
    <em>connect</em> to the display (e.g. XOpenDisplay () on an X-Windows
    server). 
*/
- (id) initWithAttributes: (NSDictionary *)attributes
{
  [super init];

  server_info = [attributes mutableCopy];
  event_queue = [[NSMutableArray allocWithZone: [self zone]]
			initWithCapacity: 32];
  drag_types = NSCreateMapTable(NSIntMapKeyCallBacks,
                NSObjectMapValueCallBacks, 0);

  return self;
}

/** Return information used to create the server */
- (NSDictionary *) attributes
{
  return AUTORELEASE([server_info copy]);
}

/**
   Causes the server to disconnect from the display. If the receiver
   is the current server, it removes itself and sets the current 
   server to nil. Sending any more messages to the receiver after this
   is likely to cause severe problems and probably crash the
   application. 
*/
- (void) closeServer
{
  if (self == GSCurrentServer())
    [GSDisplayServer setCurrentServer: nil];
}

- (void) dealloc
{
  DESTROY(server_info);
  DESTROY(event_queue);
  NSFreeMapTable(drag_types);
  [super dealloc];
}

- glContextClass
{
  return nil;
}

- glPixelFormatClass
{
  return nil;
}


/* Drag and drop support. */
/** Convienience method that calls -addDragTypes:toWindow: using the
    server that controls win.
*/
+ (BOOL) addDragTypes: (NSArray*)types toWindow: (NSWindow *)win
{
  return [GSServerForWindow(win) addDragTypes: types toWindow: win];
}

/** Convienience method that calls -removeDragTypes:fromWindow: using the
    server that controls win.
*/
+ (BOOL) removeDragTypes: (NSArray*)types fromWindow: (NSWindow *)win
{
  return [GSServerForWindow(win) removeDragTypes: types fromWindow: win];
}

/** Convienience method that calls -dragTypesForWindow: using the
    server that controls win.
*/
+ (NSCountedSet*) dragTypesForWindow: (NSWindow *)win
{
  return [GSServerForWindow(win) dragTypesForWindow: win];
}

/**
 * Add (increment count by 1) each drag type to those registered
 * for the window.  If this results in a change to the types registered
 * in the counted set, return YES, otherwise return NO.
 * Subclasses should override this method, call 'super' and take
 * appropriate action if the method returns 'YES'.
 */
- (BOOL) addDragTypes: (NSArray*)types toWindow: (NSWindow *)win
{
  NSCountedSet	*old = (NSCountedSet*)NSMapGet(drag_types, (void*)win);
  NSEnumerator *drag_enum = [types objectEnumerator];
  id            type;
  unsigned	originalCount;

  /*
   * Make sure the set exists.
   */
  if (old == nil)
    {
      old = [NSCountedSet new];
      NSMapInsert(drag_types, (void*)win, (void*)(gsaddr)old);
      RELEASE(old);
    }
  originalCount = [old count];

  while ((type = [drag_enum nextObject]))
    {
      [old addObject: type];
    }
  if ([old count] == originalCount)
    return NO;
  return YES;
}

/**
 * Remove (decrement count by 1) each drag type from those registered
 * for the window.  If this results in a change to the types registered
 * in the counted set, return YES, otherwise return NO.
 * If given 'nil' as the array of types, remove ALL.
 * Subclasses should override this method, call 'super' and take
 * appropriate action if the method returns 'YES'.
 */
- (BOOL) removeDragTypes: (NSArray*)types fromWindow: (NSWindow *)win
{
  NSCountedSet	*old = (NSCountedSet*)NSMapGet(drag_types, (void*)win);
  NSEnumerator *drag_enum = [types objectEnumerator];

  if (types == nil)
    {
      if (old == nil)
	return NO;
      NSMapRemove(drag_types, (void*)win);
      return YES;
    }
  else if (old == nil)
    {
      return NO;
    }
  else
    {
      unsigned	originalCount = [old count];
      id o;

      while ((o = [drag_enum nextObject]))
	{
	  [old removeObject: o];
	}
      if ([old count] == originalCount)
	return NO;
      return YES;
    }
}

/** Returns the drag types set for the window win. */
- (NSCountedSet*) dragTypesForWindow: (NSWindow *)win
{
  return (NSCountedSet*)NSMapGet(drag_types, (void *)win);
}

/** Returns an instance of a class which implements the NSDraggingInfo
    protocol. */
- (id <NSDraggingInfo>) dragInfo
{
  [self subclassResponsibility: _cmd];
  return nil;
}

- (BOOL) slideImage: (NSImage*)image from: (NSPoint)from to: (NSPoint)to
{
  return [GSSlideView _slideImage: image from: from to: to];
}

- (void) restrictWindow: (int)win toImage: (NSImage*)image
{
  [self subclassResponsibility: _cmd];
}

/* Screen information */
/** Retuns the resolution, in points, for the indicated screen of the
    display. */
- (NSSize) resolutionForScreen: (int)screen
{
  /*[self subclassResponsibility: _cmd];*/
  return NSMakeSize(72, 72);
}

/** Retuns the bounds, in pixels, for the indicated screen of the
    display. */
- (NSRect) boundsForScreen: (int)screen
{
  [self subclassResponsibility: _cmd];
  return NSZeroRect;
}

/** Returns the default depth of windows that are created on screen. */
- (NSWindowDepth) windowDepthForScreen: (int)screen
{
  [self subclassResponsibility: _cmd];
  return 0;
}

/** Returns a null terminated list of possible window depths for
    screen. */
- (const NSWindowDepth *) availableDepthsForScreen: (int)screen
{
  [self subclassResponsibility: _cmd];
  return NULL;
}

/**
   Returns an array of NSNumbers, where each number describes a screen
   that is available on this display. The default screen is listed first.
 */
- (NSArray *) screenList
{
  [self subclassResponsibility: _cmd];
  return nil;
}

/**
   Returns a display dependant pointer that describes the internal
   connection to the display. On X-Windows, for example, this is a
   pointer to the <code>Display</code> variable.  */
- (void *) serverDevice
{
  [self subclassResponsibility: _cmd];
  return NULL;
}

/**
   Returns a display dependant pointer that describes the internal
   window representation for win. On X-Windows, for example, this is a
   pointer to the <code>Window</code> variable. */
- (void *) windowDevice: (int)win
{
  [self subclassResponsibility: _cmd];
  return NULL;
}

/** Play the System Beep */
- (void) beep
{
  [self subclassResponsibility: _cmd];
}

@end

/* ----------------------------------------------------------------------- */
/* GNUstep Window operations */
/* ----------------------------------------------------------------------- */
@implementation GSDisplayServer (WindowOps)

/** Tells the receiver that it owns the window described by
    win. Concrete subclasses must call this function when creating a
    window. Do not call this method in any other case, particularly
    for a window that has already been created */
- (void) _setWindowOwnedByServer: (int)win
{
  NSMapInsert (windowmaps, (void*)win,  self);
}

/** Creates a window whose location and size is described by frame and
    whose backing store is described by type. This window is not
    mapped to the screen by this call. Note that frame includes the title
    bar and all other window decorations. In many cases the window
    manager controls these aspects of the window. The actual drawable
    area of the window may vary depending on the window manager involved.
    Use -styleoffsets::::: to determine the extent of the window decorations.
*/
- (int) window: (NSRect)frame : (NSBackingStoreType)type : (unsigned int)style
{
  int sn = [[server_info objectForKey: GSScreenNumber] intValue];

  return [self window: frame : type : style : sn];
}

/** Like window::: only there is an additional argument to specify which
    screen the window will display on */
- (int) window: (NSRect)frame : (NSBackingStoreType)type : (unsigned int)style
	      : (int)screen
{
  [self subclassResponsibility: _cmd];
  return 0;
}

/** Destroys the representation of the window and frees and memory
    associated with it. */
- (void) termwindow: (int) win
{
  [self subclassResponsibility: _cmd];
}

/** Sets the style of the window. See [NSWindow -styleMask] for a
    description of the available styles */
- (void) stylewindow: (unsigned int) style : (int) win
{
  [self subclassResponsibility: _cmd];
}

/** Changes window's the backing store to type */
- (void) windowbacking: (NSBackingStoreType)type : (int) win
{
  [self subclassResponsibility: _cmd];
}

/** Sets the window title */
- (void) titlewindow: (NSString *) window_title : (int) win
{
  [self subclassResponsibility: _cmd];
}

/** Miniaturizes the window */
- (void) miniwindow: (int) win
{
  [self subclassResponsibility: _cmd];
}

/** Returns YES if the application should create the miniwindow counterpart
    to the full size window and own it. Some display systems handle the
    miniwindow themselves. In this case the backend subclass should
    override this method to return NO. */
- (BOOL) appOwnsMiniwindow
{
  return YES;
}


/** Sets the window device information for the current NSGraphicsContext,
    typically by calling [NSGraphicsContext -GSSetDevice:::],
    although depending on the concrete implmentation, more information
    than this may need to be exchanged. */
- (void) windowdevice: (int) win
{
  [self subclassResponsibility: _cmd];
}

/** Causes the window to be ordered onto or off the screen depending
    on the value of op. The window is ordered relative to otherWin. */
- (void) orderwindow: (int) op : (int) otherWin : (int) win
{
  [self subclassResponsibility: _cmd];
}

/** Moves the bottom left cornder of the window to loc */
- (void) movewindow: (NSPoint)loc : (int) win
{
  [self subclassResponsibility: _cmd];
}

/** Moves and resizes the window on the screen as described by frame. */
- (void) placewindow: (NSRect)frame : (int) win
{
  [self subclassResponsibility: _cmd];
}

/** Retuns the frame of the window on the screen */
- (NSRect) windowbounds: (int) win
{
  [self subclassResponsibility: _cmd];
  return NSZeroRect;
}

/** Set the level of the window as in [NSWindow -setLevel] */
- (void) setwindowlevel: (int) level : (int) win
{
  [self subclassResponsibility: _cmd];
}

/** Returns the window level as in [NSWindow -level] */
- (int) windowlevel: (int) win
{
  [self subclassResponsibility: _cmd];
  return 0;
}

/** Returns the list of windows that the server controls */
- (NSArray *) windowlist
{
  [self subclassResponsibility: _cmd];
  return nil;
}

/** Returns the depth of the window */
- (int) windowdepth: (int) win
{
  [self subclassResponsibility: _cmd];
  return 0;
}

/** Set the maximum size of the window */
- (void) setmaxsize: (NSSize)size : (int) win
{
  [self subclassResponsibility: _cmd];
}

/** Set the minimum size of the window */
- (void) setminsize: (NSSize)size : (int) win
{
  [self subclassResponsibility: _cmd];
}

/** Set the resize incremenet of the window */
- (void) setresizeincrements: (NSSize)size : (int) win
{
  [self subclassResponsibility: _cmd];
}

/** Causes buffered graphics to be flushed to the screen */
- (void) flushwindowrect: (NSRect)rect : (int) win
{
  [self subclassResponsibility: _cmd];
}

/** Returns the dimensions of the window that are inside the window
    frame but are controlled by the window manager. For instance, t
    gives the height of the title bar for the window */
- (void) styleoffsets: (float*) l : (float*) r : (float*) t : (float*) b 
		     : (unsigned int) style
{
  [self subclassResponsibility: _cmd];
}

/** Sets the document edited flag for the window */
- (void) docedited: (int) edited : (int) win
{
  [self subclassResponsibility: _cmd];
}

/** Sets the input state for the window given by the
    GSWindowInputState constant.  Instructs the window manager that the
    specified window is 'key', 'main', or just a normal window.  */
- (void) setinputstate: (int)state : (int)win
{
  [self subclassResponsibility: _cmd];
}

/** Forces focus to the window so that all key events are sent to this
    window */
- (void) setinputfocus: (int) win
{
  [self subclassResponsibility: _cmd];
}

/** Returns the current mouse location on the default screen. If the
    pointer is not on the default screen, an invalid point (-1,-1} is
    returned. */
- (NSPoint) mouselocation
{
  [self subclassResponsibility: _cmd];
  return NSZeroPoint;
}

/** Returns the current mouse location on aScreen. If the pointer is
    not on aScreen, this method acts like -mouselocation. If aScreen is -1,
    then the location of the mouse on any screen is returned. The
    win pointer returns the window number of the GNUstep window
    that the mouse is in or 0 if it is not in a window. */
- (NSPoint) mouseLocationOnScreen: (int)aScreen window: (int *)win
{
  [self subclassResponsibility: _cmd];
  return NSZeroPoint;
}

/** Grabs the pointer device so that all future mouse events will be
    directed only to the window win. If successful, the return value
    is YES and this message must be balanced by a -releasemouse
    message.  */
- (BOOL) capturemouse: (int) win
{
  [self subclassResponsibility: _cmd];
  return NO;
}

/** Release a previous captured mouse from -capturemouse: */
- (void) releasemouse
{
  [self subclassResponsibility: _cmd];
}

/** Hides the cursor */
- (void) hidecursor
{
  [self subclassResponsibility: _cmd];
}

/** Show a previously hidden cursor */
- (void) showcursor
{
  [self subclassResponsibility: _cmd];
}

/** Create a standard cursor (such as an arror or IBeam). Returns a
    pointer to the internal device representation that can be used
    later to make this cursor the current one
*/
- (void) standardcursor: (int) style : (void**) cid
{
  [self subclassResponsibility: _cmd];
}

/** Create a cursor from an image. Returns a pointer to the internal
    device representation that can be used later to make this cursor
    the current one */
- (void) imagecursor: (NSPoint)hotp : (int)w : (int)h : (int) colors 
		    : (const char*) image : (void**) cid
{
  [self subclassResponsibility: _cmd];
}

/** Set the cursor given by the cid representation as being the
    current cursor. The cursor has a foreground color fg and a
    background color bg. To keep the default color for the cursor, pass
    nil for fg and bg. */
- (void) setcursorcolor: (NSColor *)fg : (NSColor *)bg : (void*) cid
{
  [self subclassResponsibility: _cmd];
}

@end

/* ----------------------------------------------------------------------- */
/* GNUstep Event Operations */
/* ----------------------------------------------------------------------- */
@implementation GSDisplayServer (EventOps)
- (NSEvent*) getEventMatchingMask: (unsigned)mask
		       beforeDate: (NSDate*)limit
			   inMode: (NSString*)mode
			  dequeue: (BOOL)flag
{
  unsigned	pos = 0;	/* Position in queue scanned so far	*/
  NSRunLoop	*loop = nil;

  do
    {
      unsigned	count = [event_queue count];
      NSEvent	*event;
      unsigned	i = 0;

      if (count == 0)
	{
	  event = nil;
	}
      else if (mask == NSAnyEventMask)
	{
	  /*
	   * Special case - if the mask matches any event, we just get the
	   * first event on the queue.
	   */
	  event = [event_queue objectAtIndex: 0];
	}
      else
	{
	  event = nil;
	  /*
	   * Scan the queue from the last position we have seen, up to the end.
	   */
	  if (count > pos)
	    {
	      unsigned	end = count - pos;
	      NSRange	r = NSMakeRange(pos, end);
	      NSEvent	*events[end];

	      [event_queue getObjects: events range: r];
	      for (i = 0; i < end; i++)
		{
		  BOOL	matched = NO;

		  switch ([events[i] type])
		    {
		      case NSLeftMouseDown:
			if (mask & NSLeftMouseDownMask)
			  matched = YES;
			break;

		      case NSLeftMouseUp:
			if (mask & NSLeftMouseUpMask)
			  matched = YES;
			break;

		      case NSOtherMouseDown:
			if (mask & NSOtherMouseDownMask)
			  matched = YES;
			break;

		      case NSOtherMouseUp:
			if (mask & NSOtherMouseUpMask)
			  matched = YES;
			break;

		      case NSRightMouseDown:
			if (mask & NSRightMouseDownMask)
			  matched = YES;
			break;

		      case NSRightMouseUp:
			if (mask & NSRightMouseUpMask)
			  matched = YES;
			break;

		      case NSMouseMoved:
			if (mask & NSMouseMovedMask)
			  matched = YES;
			break;

		      case NSMouseEntered:
			if (mask & NSMouseEnteredMask)
			  matched = YES;
			break;

		      case NSMouseExited:
			if (mask & NSMouseExitedMask)
			  matched = YES;
			break;

		      case NSLeftMouseDragged:
			if (mask & NSLeftMouseDraggedMask)
			  matched = YES;
			break;

		      case NSOtherMouseDragged:
			if (mask & NSOtherMouseDraggedMask)
			  matched = YES;
			break;

		      case NSRightMouseDragged:
			if (mask & NSRightMouseDraggedMask)
			  matched = YES;
			break;

		      case NSKeyDown:
			if (mask & NSKeyDownMask)
			  matched = YES;
			break;

		      case NSKeyUp:
			if (mask & NSKeyUpMask)
			  matched = YES;
			break;

		      case NSFlagsChanged:
			if (mask & NSFlagsChangedMask)
			  matched = YES;
			break;

		      case NSAppKitDefined:
			if (mask & NSAppKitDefinedMask)
			  matched = YES;
			break;

		      case NSSystemDefined:
			if (mask & NSSystemDefinedMask)
			  matched = YES;
			break;

		      case NSApplicationDefined:
			if (mask & NSApplicationDefinedMask)
			  matched = YES;
			break;

		      case NSPeriodic:
			if (mask & NSPeriodicMask)
			  matched = YES;
			break;

		      case NSCursorUpdate:
			if (mask & NSCursorUpdateMask)
			  matched = YES;
			break;

		      default:
			break;
		    }
		  if (matched)
		    {
		      event = events[i];
		      break;
		    }
		}
	    }
	}

      /*
       * Note the positon we have read up to.
       */
      pos += i;

      /*
       * If we found a matching event, we (depending on the flag) de-queue it.
       * We return the event RETAINED - the caller must release it.
       */
      if (event)
	{
	  RETAIN(event);
	  if (flag)
	    {
	      [event_queue removeObjectAtIndex: pos];
	    }
	  return AUTORELEASE(event);
	}
      if (loop == nil)
	{
	  loop = [NSRunLoop currentRunLoop];
	}
      if ([loop runMode: mode beforeDate: limit] == NO)
	{
	  break;	// Nothing we can do ... no input handlers.
	}
    }
  while ([limit timeIntervalSinceNow] > 0.0);

  return nil;	/* No events in specified time	*/
}

- (void) discardEventsMatchingMask: (unsigned)mask
		       beforeEvent: (NSEvent*)limit
{
  unsigned		index = [event_queue count];

  /*
   *	If there is a range to use - remove all the matching events in it
   *    which were created before the specified event.
   */
  if (index > 0)
    {
      NSTimeInterval	when = [limit timestamp];
      NSEvent		*events[index];

      [event_queue getObjects: events];

      while (index-- > 0)
	{
	  NSEvent	*event = events[index];

	  if ([event timestamp] < when)
	    {	
	      BOOL	shouldRemove = NO;

	      if (mask == NSAnyEventMask)
		{
		  shouldRemove = YES;
		}
	      else
		{
		  switch ([event type])
		    {
		      case NSLeftMouseDown:
			if (mask & NSLeftMouseDownMask)
			  shouldRemove = YES;
			break;

		      case NSLeftMouseUp:
			if (mask & NSLeftMouseUpMask)
			  shouldRemove = YES;
			break;

		      case NSOtherMouseDown:
			if (mask & NSOtherMouseDownMask)
			  shouldRemove = YES;
			break;

		      case NSOtherMouseUp:
			if (mask & NSOtherMouseUpMask)
			  shouldRemove = YES;
			break;

		      case NSRightMouseDown:
			if (mask & NSRightMouseDownMask)
			  shouldRemove = YES;
			break;

		      case NSRightMouseUp:
			if (mask & NSRightMouseUpMask)
			  shouldRemove = YES;
			break;

		      case NSMouseMoved:
			if (mask & NSMouseMovedMask)
			  shouldRemove = YES;
			break;

		      case NSMouseEntered:
			if (mask & NSMouseEnteredMask)
			  shouldRemove = YES;
			break;

		      case NSMouseExited:
			if (mask & NSMouseExitedMask)
			  shouldRemove = YES;
			break;

		      case NSLeftMouseDragged:
			if (mask & NSLeftMouseDraggedMask)
			  shouldRemove = YES;
			break;

		      case NSOtherMouseDragged:
			if (mask & NSOtherMouseDraggedMask)
			  shouldRemove = YES;
			break;

		      case NSRightMouseDragged:
			if (mask & NSRightMouseDraggedMask)
			  shouldRemove = YES;
			break;

		      case NSKeyDown:
			if (mask & NSKeyDownMask)
			  shouldRemove = YES;
			break;

		      case NSKeyUp:
			if (mask & NSKeyUpMask)
			  shouldRemove = YES;
			break;

		      case NSFlagsChanged:
			if (mask & NSFlagsChangedMask)
			  shouldRemove = YES;
			break;

		      case NSPeriodic:
			if (mask & NSPeriodicMask)
			  shouldRemove = YES;
			break;

		      case NSCursorUpdate:
			if (mask & NSCursorUpdateMask)
			  shouldRemove = YES;
			break;

		      default:
			break;
		    }
		}
	      if (shouldRemove)
		[event_queue removeObjectAtIndex: index];
	    }
	}
    }
}

- (void) postEvent: (NSEvent*)anEvent atStart: (BOOL)flag
{
  if (flag)
    [event_queue insertObject: anEvent atIndex: 0];
  else
    [event_queue addObject: anEvent];
}

@end
