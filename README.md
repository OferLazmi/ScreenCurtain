# ScreenCurtain

ScreenCurtain is a menu-bar app. It covers the screen so a person in the room sees a lock screen, while the Mac stays logged in. Other programs can still type and click. Keys and clicks from the physical keyboard and mouse do nothing while the cover is up.

The cover is not a real lock. It does not ask for a password, and it does not record what you type.

## Download

The ready-made app runs on Apple silicon Macs only.

[Download ScreenCurtain for Apple silicon](https://github.com/OferLazmi/ScreenCurtain/releases/download/v1.0/ScreenCurtain-macOS-arm64.zip)

1. Unzip the file.
2. Move `ScreenCurtain.app` to the Applications folder.
3. The first time, right-click the app and choose Open.
4. A lock icon appears in the menu bar. There is no Dock icon.

An Intel Mac cannot run this download. Build it on that Mac with the steps below.

## Allow the app to see the keyboard

The first time you choose **Cover screen**, macOS asks for permission.

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Turn ScreenCurtain on.
3. If **Input Monitoring** also lists ScreenCurtain, turn it on there too.

The app cannot turn this on by itself. You have to click the switch. After a new build, turn the switch off and on again.

## What to do

- **Cover screen** puts a black page on every display. It shows a lock, the time, and the date. It also covers the menu bar and the Dock.
- Press **F10** three times, quickly, to cover the screen. On a MacBook, F10 is often the mute key, so three presses of the mute key do the same thing. Those presses still change the mute setting. **Fn+F10** three times also works.
- Typing, clicking, scrolling, and trackpad gestures from the person at the Mac do nothing while the cover is up.
- Input sent by other programs, such as automation, AppleScript, Python, or Quartz, still reaches the apps underneath.
- Press **F10** once to remove the cover. The lock icon stays in the menu bar.
- **Keep awake while covered** is on by default. The screen stays on, and the Mac does not go to sleep by itself. Click that menu item to turn it off. The Mac remembers your choice. Closing the lid still sleeps the Mac.
- **Quit** stops the app and removes the icon.

ScreenCurtain is not added to Login Items. After a restart, open `/Applications/ScreenCurtain.app` again.

If F10 does not close the cover, force-quit ScreenCurtain, or run:

```sh
killall ScreenCurtain
```

## Build

Install Xcode, or the Xcode command line tools. If `swiftc` is missing, run:

```sh
xcode-select --install
```

From this folder, run:

```sh
mkdir -p ScreenCurtain.app/Contents/MacOS ScreenCurtain.app/Contents/Resources
swiftc ScreenCurtain.swift -O -o ScreenCurtain.app/Contents/MacOS/ScreenCurtain -framework Cocoa
cp Info.plist ScreenCurtain.app/Contents/Info.plist
cp ScreenCurtain.icns ScreenCurtain.app/Contents/Resources/ScreenCurtain.icns
codesign --force --deep --sign - ScreenCurtain.app
cp -R ScreenCurtain.app /Applications/
open /Applications/ScreenCurtain.app
```

The app you just built runs only on that kind of Mac. An Apple silicon build does not run on Intel, and an Intel build does not run on Apple silicon.

## Limits

- A person can still hold the power button and restart the Mac.
- A four-finger trackpad swipe may still open Mission Control.
- The cover hides the screen. It does not protect files.
