# threefingerfn

Hold the Fn key with three fingers on the trackpad. Built for push-to-talk dictation on macOS.

- Rest three fingers on the trackpad for 0.5 seconds. The tool holds **Fn**. No click is needed.
- Lift all your fingers. The tool releases Fn, then presses **Return** 0.75 seconds later. This gives your dictation app time to finish the transcript.
- Press **Escape** while you hold, or before Return fires. The tool releases Fn and sends no Return. The dictation app still receives the Escape.
- Shorter three-finger touches, swipes, and normal clicks work as usual.

## Requirements

- macOS with a trackpad.
- Xcode command line tools (`xcode-select --install`) for `swiftc`.
- Accessibility permission for the built binary.

## Build and install

`build.sh` compiles `main.swift`, signs it, and copies it to `~/bin/threefingerfn`.

Create a code-signing certificate once:

1. Open Keychain Access > Certificate Assistant > Create a Certificate.
2. Set the name to `threefingerfn-dev` and the type to **Code Signing**.

Then build:

```bash
./build.sh
```

### Why the certificate matters

macOS ties the Accessibility grant to the binary's code signature. An ad-hoc signature changes on every build, so the grant stops working after each rebuild. A fixed certificate keeps the signature identity stable, so you grant the permission once.

If you use a different certificate name, change `IDENTITY` in `build.sh`.

## Permission

1. Run the binary once, or load the launch agent.
2. Open System Settings > Privacy & Security > Accessibility.
3. Add `~/bin/threefingerfn` and turn it on.

The tool waits and starts by itself when you grant the permission. If the grant does not take effect, remove all old `threefingerfn` rows from the list and add the binary again.

## Usage

```bash
~/bin/threefingerfn [holdDelay] [enterDelay] [fingers]
```

| Argument | Default | Meaning |
| --- | --- | --- |
| `holdDelay` | `0.5` | Seconds the three fingers rest before Fn goes down. |
| `enterDelay` | `0.5` | Seconds after release before Return. A negative value turns Return off. |
| `fingers` | `3` | Number of resting fingers that holds Fn. Use `4` to make accidental triggers less likely. |

Example: `threefingerfn 0.7 -1` waits 0.7 seconds and never presses Return.

## Run at login

Save this as `~/Library/LaunchAgents/com.rock.threefingerfn.plist`. Replace `YOU` with your user name.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.rock.threefingerfn</string>
  <key>ProgramArguments</key><array>
    <string>/Users/YOU/bin/threefingerfn</string>
    <string>0.5</string>
    <string>0.75</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>/Users/YOU/Library/Logs/threefingerfn.log</string>
  <key>StandardErrorPath</key><string>/Users/YOU/Library/Logs/threefingerfn.log</string>
</dict></plist>
```

Load it with `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.rock.threefingerfn.plist`. After that, `./build.sh` restarts the agent for you.

## Notes and limits

- The tool reads finger count with the private `MultitouchSupport` framework. Apple can change or remove it in a macOS update.
- Three fingers that rest for the hold delay trigger Fn. A slow three-finger swipe can trigger it too. Raise `holdDelay` if this happens.
- After Fn goes down, the finger count can change. Only a full lift releases Fn.
- The tool reattaches all trackpads when macOS adds a trackpad device (for example, a Magic Trackpad reconnects) and after wake. A reconnected trackpad keeps its device ID but its old device object stops sending touches.
- With `fingers` set to `4`, a slow four-finger swipe (Spaces, Mission Control) can trigger Fn. Raise `holdDelay` if this happens.
- While Fn is held, a hard press does not click through.

## License

MIT
