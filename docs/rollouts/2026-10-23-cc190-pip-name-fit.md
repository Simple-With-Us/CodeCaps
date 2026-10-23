# CC-190: Keep PiP Names While They Fit

The owner supplied two Mac PiP screenshots at nearly identical widths.
One hid every provider name despite unused space; the other retained names
inside a much wider column than the names needed.

The PiP reserved a fixed 150-point title column and used that entire width
to choose its richest detail level.  Crossing that threshold removed names
even when their actual text and the quota meters could still fit.

The widget now measures the widest pinned name using its rendered font,
rounds up to whole points and retains the existing 150-point maximum.
That measured column drives the title frames, detail selection, horizontal
row frames and horizontal-scroll threshold.  Long names can truncate within
the existing maximum.  A spare spacer before the meters is removed so bars
can use available width.  Only visible spike flames contribute to the width
budget, with the icon frame matching the measured reservation.

The existing degradation order remains: names disappear before countdowns,
countdowns shorten to one rounded unit before disappearing, and logos
survive until the narrowest identity-free levels.

Validation uses focused width-boundary tests and native Mac PiP renders in
the existing hosted package suite.  The rendering test writes to
`CODECAPS_DOCS_RENDER_DIR`, which Swift CI already uploads as an artifact.
Local `git diff --check` is available; Swift and Xcode execution are through
GitHub-hosted macOS because this task runs on Linux.

Linear CC-190 is the work record.  The archived effort log remains unchanged.
