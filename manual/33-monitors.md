# Monitors

Omarchy assumes you're running on a 2x-capable retina-class display by default. This is what you need to get those nice, crisp programmer fonts. It's what almost all new premium laptops with high-resolution screens are optimized for. It's what you'd want to run on a 27" 5K [Apple Studio Display](https://www.apple.com/studio-display/)/[ProArt PA27JCV](https://www.asus.com/us/displays-desktops/monitors/proart/proart-display-5k-pa27jcv/)/[Samsung S9](https://www.samsung.com/us/computing/monitors/5k/27-viewfinity-s9-5k-monitor-with-thunderbolt-4-matte-display-and-smart-features-ls27c900panxza/)/[Kuycon G27P](https://kuycon.us/monitors/G27P/) or 32" 6K [Apple XDR](https://www.apple.com/pro-display-xdr/)/[ProArt PA32QCV](https://www.asus.com/displays-desktops/monitors/proart/proart-display-6k-pa32qcv/)/[Kuycon G32P](https://kuycon.us/monitors/G32P/).

Other displays are sized to match. When you connect one for the first time, Omarchy picks the scale that makes things look the same size as on your main display (the laptop's own screen, unless you choose another in the Monitor panel), from the size the display reports. A desk monitor starts out showing things a little larger than the laptop does, since it sits further away.

To change the size, open the Monitor panel from the bar and pick a scale, or use `Super + /` to go higher and `Super + Alt + /` to go lower. With _Linked displays_ selected, every display keeps in proportion when you change one. Choose _Per display_ to set each on its own; Omarchy learns from how you set a desk monitor against the laptop. `Super + Ctrl + /` matches every display to the main one again. Scales are remembered per display.

GTK and X11 applications follow the main display's scale, rounded to the whole number GTK needs, and pick up a change when they're restarted (close all windows with `Ctrl + Alt + Del` if many are oversized).

### Making text bigger or smaller

Monitor scaling changes the size of everything. If all you want is bigger or smaller _text_, there's a single knob for that:

```
omarchy display text size 14
```

That takes a pixel size between 9 and 20, and moves the Omarchy shell, GTK applications, and your terminal together, so the whole desktop stays in proportion. Run it without an argument to see where you're at, and `omarchy display text size reset` to go back to the default. Foot is the one straggler: it has no way to reload its config, so running terminals keep their old size until you open a new one.

### Extending and mirroring laptop displays

When you connect an external screen to your laptop, the display is automatically extended. But you can change that to mirroring instead using _Trigger > Hardware_ in the Omarchy menu or `Super + Ctrl + Alt + Delete`. This is especially helpful if that external screen is a projector, and you want to show something while working.

When you're extending, closing the lid on the laptop will automatically turn off the internal screen. Opening the lid will turn it back on. You can also control this manually using _Trigger > Hardware_ in the Omarchy menu or `Super + Ctrl + Delete`.

### Arranging multiple screens

Omarchy remembers where each screen goes, for every combination of screens you connect, and recognises a screen by its model and serial number, whichever port you plug it into. A screen you connect for the first time goes to the right of the main one, with the bottom edges lined up. To rearrange, open the Monitor panel and drag the screens where they sit on your desk; the star next to a screen makes it the main one, and _Identify_ shows each screen's number on it. The number is shown on a small monitor icon, at the start of each screen's bar and in the Monitor panel. Screens that are already on don't move when another one connects.

Each screen has its own workspaces. `Super + 1..0` and the bar on each screen are for that screen, the three-finger swipe stops at the last workspace in use, `Super + D` followed by a number moves the active window to that screen (numbered from the left), and `Super + Ctrl + Alt + Arrows` moves it to the screen in that direction. When a screen is disconnected, its windows come over to the main screen's active workspace, and they go back when it returns.

New windows open on the focused screen, which follows the pointer: move the pointer onto the other screen, or press `Ctrl + Alt + Tab`, to open the next app there. If you'd rather keep focus on the current screen until you click the other one, add `hl.config({ misc = { mouse_move_focuses_monitor = false } })` to `~/.config/hypr/input.lua`.

On a MacBook with Apple Silicon, the Omarchy menus and panels you open from the MacBook's own keyboard (`Super + Space`, `Super + Alt + Space`, `Super + Escape`, `Super + K`, the `Super + Ctrl` panels and any binding in `~/.config/hypr/bindings.lua` that runs `omarchy-menu` or `omarchy-shell shell toggle`) open on the MacBook's screen, and the pointer moves there too. Apps, the emoji picker and the clipboard manager open on the focused screen, as they do from an external keyboard, so with only the MacBook keyboard you open an app on the external screen by moving the pointer there first. With the lid closed or the laptop display turned off, everything opens on the focused screen.

If you want to set a screen up by hand, give it a rule in `~/.config/hypr/monitors.lua` (via _Setup > Monitors_), for example `hl.monitor({ output = "desc:BNQ BenQ LCD T4M01236019", mode = "2560x1440@144", position = "0x0", scale = 1 })`; `hyprctl monitors` shows each screen's description. Omarchy then leaves that screen's mode, position and scale to you. See [the Hyprland monitor documentation](https://wiki.hypr.land/Configuring/Basics/Monitors/) for everything a rule can do.

If you'd rather use your own setup for all of this, `omarchy-hyprland-toggle displays-off on` turns off arrangement, scaling and per-display workspaces. To keep the arrangement and scaling but have global workspaces, where `Super + 1..0` means workspace 1..0 wherever it is, use `omarchy-hyprland-toggle display-workspaces-off on` instead. If you use a workspace plugin, run `omarchy-hyprland-toggle display-workspaces-off on`. `off` turns the default back on.

### Controlling brightness

Monitor brightness is controlled by the dedicated function keys for brightness up/down. If you hold down shift while pressing these, you'll go to maximum or minimum brightness. The keys control the display you're focused on, so external monitors that speak DDC/CI are adjusted the same way as the laptop screen.

### Apple Displays

If you're using an Apple display, the regular keyboard brightness keys will also automatically work, if you're focused on the Apple display. This is done through the `asdcontrol` command.

Note that if you're using an Apple 6K XDR display, you may see a phantom screen in your `hyprctl monitors` listing. You can turn this off with something like `hl.monitor({ output = "DP-2", disabled = true })` via _Setup > Monitors_.

On Intel machines, you should be connecting to Apple displays using a regular Thunderbolt cable. On other machines without Thunderbolt, you'll typically have to use a [DP + USB-A -> USB-C cable](https://www.amazon.com/dp/B0BNX7MS6N) to make it work.
