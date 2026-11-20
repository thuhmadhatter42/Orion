import SwiftUI

/// COLOR in the window's footer, between SETTINGS and HELP: the HELP chip's look, a swatch of the
/// colour in use, lit while the colour wheel is open.
struct ColorChip: View {
    /// The colour picker is open (the app: its colour wheel; the plug-in: its swatches).
    var on = false
    var action: () -> Void = {}

    var body: some View {
        // the footer's one chip (FooterChip) with the swatch, lit while the wheel is open
        FooterChip(title: "COLOR", label: "Display colour", on: on, swatch: true, action: action)
            .nativeHelp("Pick the display colour")
            .helpTip(HelpText.color)
            .accessibility(hint: Text(on ? "Closes the colour wheel" : "Opens a colour wheel to change the display colour"))
    }
}
