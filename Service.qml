import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  property var shell: null
  property string omarchyPath: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME")
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"

  property bool lockRequested: false
  property bool pendingSessionLock: false
  property bool authenticatingPassword: false
  property bool fingerprintAuthenticating: false
  property bool passwordPamConfigured: false
  property bool fingerprintConfigured: false
  // Face unlock (Howdy) runs as its own PAM service, started once on lock and
  // again on each wake, never in a retry loop: every attempt spawns Howdy and
  // holds the camera for a few seconds, so looping would keep the camera and
  // a CPU core busy for the whole lock.
  property bool faceConfigured: false
  property bool faceAuthenticating: false
  property string faceStatus: ""
  property int faceAutoAttempts: 0
  property double faceLastAttemptAt: 0
  property bool displayBlanked: false
  property double faceResumedAt: 0
  readonly property int faceResumeGraceMs: 6000
  readonly property int faceMaxAutoAttempts: 3
  // Slightly longer than one full attempt (Howdy timeout 3 s + ~1.4 s startup).
  readonly property int faceCooldownMs: 5000
  property bool previewVisible: false
  property string enteredPassword: ""
  property string pendingPassword: ""
  property string failureMessage: ""
  property int failedAttempts: 0
  property string backgroundPath: ""
  property int backgroundVersion: 0
  property string lastEvent: "init"
  property string lastEventAt: ""
  property bool strandedLock: false
  property bool strandedLockResolved: false

  readonly property bool locked: lockRequested || sessionLock.locked || sessionLock.secure
  readonly property bool authenticating: authenticatingPassword || fingerprintAuthenticating || faceAuthenticating

  function realScreenCount() {
    var screens = Quickshell.screens || []
    var count = 0

    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i]
      if (screen && screen.name && screen.width > 0 && screen.height > 0) count += 1
    }

    return count
  }

  function hasRealScreen() {
    return realScreenCount() > 0
  }

  function queueSessionLock() {
    pendingSessionLock = true
    if (!sessionLockStabilizeTimer.running) logEvent("lock-pending: screen-stabilizing")
    sessionLockStabilizeTimer.restart()
    if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
  }

  function requestSessionLock() {
    if (!lockRequested || sessionLock.locked || sessionLock.secure) return
    if (sessionLockStabilizeTimer.running) return

    if (!hasRealScreen()) {
      if (!pendingSessionLock || lastEvent !== "lock-pending: no-real-screen") logEvent("lock-pending: no-real-screen")
      pendingSessionLock = true
      if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
      return
    }

    pendingSessionLock = false
    pendingSessionLockTimer.stop()
    sessionLock.locked = true
  }

  // ext-session-lock outlives its client, and a restart carries no lock over, so
  // a session locked this early is an orphan behind Hyprland's failsafe. Outputs
  // are often still absent here, so ask until the answer means something.
  function checkStrandedLock() {
    if (strandedLockResolved || strandedLockCheckProc.running) return

    // A lock this shell took is nobody's orphan.
    if (locked || lockRequested) {
      strandedLockResolved = true
      return
    }

    strandedLockCheckProc.running = true
  }

  function recoverStrandedLock() {
    if (!strandedLock || locked || !passwordPamConfigured) return

    strandedLock = false
    logEvent("lock-stranded: recovering")
    beginLock()
  }

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function refreshFingerprintStatus() {
    if (!fingerprintCheckProc.running) fingerprintCheckProc.running = true
  }

  function refreshFaceStatus() {
    if (!faceCheckProc.running) faceCheckProc.running = true
  }

  function logEvent(event) {
    lastEvent = event
    lastEventAt = new Date().toISOString()
    console.log("omarchy lock " + lastEventAt + " " + event)
  }

  function resetAuthenticationState() {
    enteredPassword = ""
    pendingPassword = ""
    failureMessage = ""
    failedAttempts = 0
    authenticatingPassword = false
    fingerprintAuthenticating = false
    fingerprintRetryTimer.stop()
    faceAuthenticating = false
    faceStatus = ""
    faceAutoAttempts = 0
    displayBlanked = false
    faceResumedAt = 0
    faceResumeTimer.stop()
    suspendWatch.lastTick = 0
    if (passwordPam.active) passwordPam.abort()
    if (fingerprintPam.active) fingerprintPam.abort()
    if (facePam.active) facePam.abort()
  }

  function beginLock() {
    if (!passwordPamConfigured) {
      logEvent("lock-denied: missing-pam")
      return false
    }

    resetAuthenticationState()
    lockRequested = true
    armBlankTimer()
    logEvent("lock-requested")
    queueSessionLock()

    Qt.callLater(function() {
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.refreshFaceStatus()
    })

    return true
  }

  function finishUnlock() {
    if (!root.locked && !lockRequested) return

    lockRequested = false
    pendingSessionLock = false
    sessionLockStabilizeTimer.stop()
    pendingSessionLockTimer.stop()
    resetAuthenticationState()
    idleBlankTimer.stop()
    sessionLock.locked = false
    logEvent("unlocked")
    runWake()
  }

  function armBlankTimer() {
    idleBlankTimer.armedAt = Date.now()
    idleBlankTimer.restart()
  }

  function runWake() {
    if (!wakeProcess.running) wakeProcess.running = true
    if (lockRequested) {
      armBlankTimer()
      // Coming back to a blanked lock screen is a fresh arrival: allow a new
      // round of automatic face attempts.
      if (displayBlanked) {
        displayBlanked = false
        faceAutoAttempts = 0
        faceStatus = ""
      }
      startFace(false)
    }
  }

  function runBlank() {
    if (!blankProcess.running) blankProcess.running = true
    displayBlanked = true
  }

  function submitPassword(value) {
    var password = String(value || "")
    if (!lockRequested || authenticatingPassword || password.length === 0) return

    pendingPassword = password
    runWake()
    failureMessage = ""
    authenticatingPassword = true

    if (!passwordPam.start()) {
      handlePasswordFailure()
      return
    }

    Qt.callLater(respondToPasswordPrompt)
  }

  function respondToPasswordPrompt() {
    if (!authenticatingPassword || !passwordPam.active || !passwordPam.responseRequired) return
    passwordPam.respond(pendingPassword)
  }

  function handlePasswordFailure() {
    if (!lockRequested) return

    authenticatingPassword = false
    enteredPassword = ""
    pendingPassword = ""
    failedAttempts += 1
    failureMessage = "Authentication failed (" + failedAttempts + ")"
    runWake()
  }

  function startFingerprint() {
    if (!lockRequested || !sessionLock.secure || !fingerprintConfigured) return
    if (fingerprintPam.active || fingerprintAuthenticating) return

    fingerprintAuthenticating = true
    if (!fingerprintPam.start()) {
      fingerprintAuthenticating = false
    }
  }

  function handleFingerprintFinished(result) {
    fingerprintAuthenticating = false

    if (!lockRequested) return
    if (result === PamResult.Success) {
      finishUnlock()
    } else if (fingerprintConfigured) {
      fingerprintRetryTimer.restart()
    }
  }

  // The T2 bridge that carries the camera also carries the internal keyboard
  // and trackpad. Touching the camera right after resume once wedged that
  // bridge (kernel: "t2bce_vhci: Possible desync") and took the keyboard with
  // it. With USB autosuspend disabled for the camera (udev rule) it survives
  // sleep, but the bridge still logs a pause timeout ~9 s after resume, so
  // scans wait out a grace period and then run once on their own. A suspend
  // shows up as a wall-clock jump the 1 s tick could not have made.
  function detectSuspend() {
    var now = Date.now()
    var jumped = suspendWatch.lastTick > 0 && now - suspendWatch.lastTick > suspendWatch.interval + 8000
    // Record the tick before anything below runs: runWake() re-enters this
    // function via startFace(), and must not see the same jump again.
    suspendWatch.lastTick = now
    if (jumped) {
      logEvent("face-resume: waiting " + faceResumeGraceMs + "ms for the camera")
      faceResumedAt = now
      faceAutoAttempts = 0
      faceStatus = "Camera waking up…"
      faceResumeTimer.interval = faceResumeGraceMs + 500
      faceResumeTimer.restart()
      // The panel was blanked before sleep; light it so the countdown and the
      // scan are visible without touching a key.
      runWake()
    }

    var remaining = faceResumedAt > 0 ? faceResumeGraceMs - (now - faceResumedAt) : 0
    if (remaining > 0 && !faceAuthenticating) {
      faceStatus = "Camera waking up… " + Math.ceil(remaining / 1000) + " s"
    }
    return remaining > 0
  }

  // manual = Enter on an empty field; automatic attempts are rate limited and
  // capped per wake so an unattended lock screen never keeps the camera busy.
  function startFace(manual) {
    if (!lockRequested || !sessionLock.secure || !faceConfigured) return
    if (detectSuspend()) return
    if (facePam.active || faceAuthenticating || authenticatingPassword) return
    if (pendingPassword.length > 0) return

    if (!manual) {
      if (faceAutoAttempts >= faceMaxAutoAttempts) return
      if (Date.now() - faceLastAttemptAt < faceCooldownMs) return
      faceAutoAttempts += 1
    }

    faceLastAttemptAt = Date.now()
    faceStatus = ""
    faceAuthenticating = true
    logEvent("face-start: " + (manual ? "manual" : "auto " + faceAutoAttempts))

    if (!facePam.start()) {
      faceAuthenticating = false
      faceStatus = "Face unlock unavailable"
    }
  }

  function handleFaceFinished(result) {
    faceAuthenticating = false

    if (!lockRequested) return
    if (result === PamResult.Success) {
      logEvent("face-approved")
      finishUnlock()
      return
    }

    logEvent("face-failed")
    faceStatus = "No face found"
  }

  WlSessionLock {
    id: sessionLock

    locked: false

    onSecureStateChanged: {
      root.logEvent("secure=" + secure)
      if (secure) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.startFingerprint()
        root.startFace(false)
      }
    }

    onLockStateChanged: {
      root.logEvent("session-locked=" + locked)

      if (locked) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
      }

      if (!locked && root.lockRequested) {
        root.lockRequested = false
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.resetAuthenticationState()
        root.runWake()
      }
    }

    WlSessionLockSurface {
      id: lockSurface
      color: Color.background

      LockView {
        id: lockView
        anchors.fill: parent
        backgroundPath: root.backgroundPath
        backgroundVersion: root.backgroundVersion
        fingerprintConfigured: root.fingerprintConfigured
        faceConfigured: root.faceConfigured
        faceAuthenticating: root.faceAuthenticating
        faceStatus: root.faceStatus
        authenticatingPassword: root.authenticatingPassword
        failureMessage: root.failureMessage
        failedAttempts: root.failedAttempts
        inputEnabled: root.lockRequested
        loadBackground: root.locked
        passwordText: root.enteredPassword
        onPasswordTextEdited: function(password) { root.enteredPassword = password }
        onSubmitPassword: function(password) { root.submitPassword(password) }
        onRetryFaceRequested: root.startFace(true)
        onClearFailureRequested: root.failureMessage = ""
        onWakeRequested: root.runWake()
      }

    }
  }

  PanelWindow {
    id: previewWindow
    visible: root.previewVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-lock-preview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    LockView {
      anchors.fill: parent
      backgroundPath: root.backgroundPath
      backgroundVersion: root.backgroundVersion
      fingerprintConfigured: root.fingerprintConfigured
      faceConfigured: root.faceConfigured
      faceAuthenticating: false
      faceStatus: ""
      authenticatingPassword: false
      failureMessage: ""
      failedAttempts: 0
      inputEnabled: false
      loadBackground: root.previewVisible
      passwordText: ""
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: root.previewVisible = false
    }
  }

  PamContext {
    id: passwordPam
    config: "omarchy-lock-password"
    user: root.userName

    onResponseRequiredChanged: root.respondToPasswordPrompt()
    onPamMessage: root.respondToPasswordPrompt()

    onCompleted: function(result) {
      root.authenticatingPassword = false
      root.pendingPassword = ""

      if (!root.lockRequested) return
      if (result === PamResult.Success) root.finishUnlock()
      else root.handlePasswordFailure()
    }

    onError: function(error) {
      root.handlePasswordFailure()
    }
  }

  PamContext {
    id: fingerprintPam
    config: "omarchy-lock-fingerprint"
    user: root.userName

    onCompleted: function(result) {
      root.handleFingerprintFinished(result)
    }

    onError: function(error) {
      root.fingerprintAuthenticating = false
      if (root.lockRequested && root.fingerprintConfigured) fingerprintRetryTimer.restart()
    }
  }

  Timer {
    id: fingerprintRetryTimer
    interval: 250
    repeat: false
    onTriggered: root.startFingerprint()
  }

  // One deferred scan: 1 s after a lid open while awake, or the full grace
  // period after a resume from sleep (interval is set by the caller).
  Timer {
    id: faceResumeTimer
    interval: 1000
    repeat: false
    onTriggered: root.startFace(true)
  }

  // Ticks while locked so a suspend leaves a visible gap in lastTick.
  Timer {
    id: suspendWatch
    property double lastTick: 0
    interval: 1000
    repeat: true
    running: root.lockRequested && root.faceConfigured
    onTriggered: root.detectSuspend()
  }

  PamContext {
    id: facePam
    config: "omarchy-lock-face"
    user: root.userName

    onCompleted: function(result) {
      root.handleFaceFinished(result)
    }

    onError: function(error) {
      root.faceAuthenticating = false
      if (root.lockRequested) root.faceStatus = "Face unlock error"
    }
  }

  Process {
    id: faceCheckProc
    command: ["bash", "-c", "if [[ -f /etc/pam.d/omarchy-lock-face && -f /usr/lib/security/pam_howdy.so ]]; then echo yes; else echo no; fi"]
    stdout: StdioCollector { id: faceCheckStdout; waitForEnd: true }
    onExited: {
      root.faceConfigured = String(faceCheckStdout.text || "").trim() === "yes"
      if (root.lockRequested && root.faceConfigured) root.startFace(false)
      else if (!root.faceConfigured && facePam.active) facePam.abort()
    }
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = String(text || "").trim()
        if (next !== root.backgroundPath) {
          root.backgroundPath = next
          root.backgroundVersion += 1
        }
      }
    }
  }

  Process {
    id: fingerprintCheckProc
    command: ["bash", "-c", "if [[ -f /etc/pam.d/omarchy-lock-fingerprint ]] && command -v fprintd-list >/dev/null 2>&1 && fprintd-list \"$USER\" 2>/dev/null | grep -qi finger; then echo yes; else echo no; fi"]
    stdout: StdioCollector { id: fingerprintCheckStdout; waitForEnd: true }
    onExited: {
      root.fingerprintConfigured = String(fingerprintCheckStdout.text || "").trim() === "yes"
      if (root.lockRequested && root.fingerprintConfigured) root.startFingerprint()
      else if (!root.fingerprintConfigured && fingerprintPam.active) fingerprintPam.abort()
    }
  }

  Process {
    id: strandedLockCheckProc
    command: ["bash", "-c", "omarchy-hyprland-session-locked"]
    onExited: function(exitCode) {
      // No output to read the lock off yet.
      if (exitCode === 2) return

      root.strandedLockResolved = true

      // A lock taken while this was in flight is this shell's own.
      root.strandedLock = exitCode === 0 && !root.locked && !root.lockRequested
      root.recoverStrandedLock()
    }
  }

  Process {
    id: wakeProcess
    command: ["bash", "-c", "omarchy-system-wake"]
  }

  Process {
    id: blankProcess
    command: ["bash", "-c", "omarchy-brightness-keyboard off; omarchy-brightness-display off"]
  }

  Timer {
    id: idleBlankTimer
    interval: 5000
    repeat: false
    property double armedAt: 0
    onTriggered: {
      // A countdown frozen by suspend fires right after resume, which would
      // blank the freshly woken unlock screen under the user. Wall-clock time
      // exposes the gap: take a fresh run-up instead of blanking.
      if (Date.now() - armedAt > interval + 2000) {
        root.armBlankTimer()
        return
      }
      // Only a password check in flight should hold the display up. The
      // fingerprint PAM stays armed for the whole lock, so gating on
      // `authenticating` here would keep the panel lit until unlock.
      // Nor during the post-resume countdown: blanking there would turn the
      // panel off right before the automatic scan.
      var inResumeGrace = root.faceResumedAt > 0 && Date.now() - root.faceResumedAt < root.faceResumeGraceMs + 500
      if (inResumeGrace) {
        root.armBlankTimer()
        return
      }
      if (root.lockRequested && !root.authenticatingPassword && !root.faceAuthenticating) root.runBlank()
    }
  }

  Timer {
    id: sessionLockStabilizeTimer
    interval: 500
    repeat: false
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: pendingSessionLockTimer
    interval: 100
    repeat: true
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: strandedLockRetryTimer
    interval: 500
    repeat: true
    // Covers the compositor settling; screens coming back re-arm it.
    readonly property int budget: 20
    property int remaining: 20
    running: !root.strandedLockResolved && remaining > 0

    function rearm() {
      if (!root.strandedLockResolved) remaining = budget
    }

    onTriggered: {
      remaining -= 1
      root.checkStrandedLock()
    }
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      root.requestSessionLock()

      // A monitor still coming up has no workspace, so cannot answer yet.
      strandedLockRetryTimer.rearm()
      root.checkStrandedLock()
    }
  }

  onAuthenticatingPasswordChanged: {
    if (!lockRequested) return
    if (authenticatingPassword) idleBlankTimer.stop()
    else armBlankTimer()
  }

  // A face attempt that was cut short by the blank timer would fail for lack
  // of light, so the display stays up while it runs and blanks afterwards.
  onFaceAuthenticatingChanged: {
    if (!lockRequested || faceAuthenticating) return
    armBlankTimer()
  }

  FileView {
    path: "/etc/pam.d/omarchy-lock-password"
    watchChanges: true
    printErrors: false
    onLoaded: root.passwordPamConfigured = true
    onLoadFailed: root.passwordPamConfigured = false
    onFileChanged: reload()
  }

  // No lock before PAM is known good. An answer from before then may be stale --
  // the failsafe can be cleared from a TTY -- so re-ask rather than act on it.
  onPasswordPamConfiguredChanged: {
    if (!passwordPamConfigured) return

    strandedLock = false
    strandedLockResolved = false
    strandedLockRetryTimer.rearm()
    checkStrandedLock()
  }

  Component.onCompleted: {
    refreshBackground()
    refreshFingerprintStatus()
    refreshFaceStatus()
    checkStrandedLock()
  }

  IpcHandler {
    target: "lock"

    function lock(): string {
      if (!root.passwordPamConfigured) return "missing-pam"
      if (!root.locked && !root.beginLock()) return "failed"
      return "ok"
    }

    function isLocked(): string {
      return root.locked ? "true" : "false"
    }

    // Lid open / resume: light the screen and give the camera one fresh look,
    // as if the user had just arrived. Bound in ~/.config/hypr/bindings.lua, see the README.
    function faceRetry(): string {
      if (!root.lockRequested) return "not-locked"
      if (!root.faceConfigured) return "no-face"
      root.logEvent("face-retry: lid-open")
      // A lid open after sleep: detectSuspend has already scheduled the scan
      // for the end of the grace period, just light the display meanwhile.
      if (root.detectSuspend()) {
        root.runWake()
        return "resume-grace"
      }
      root.faceAutoAttempts = 0
      root.faceStatus = ""
      root.runWake()
      faceResumeTimer.interval = 1000
      faceResumeTimer.restart()
      return "ok"
    }

    function status(): string {
      return JSON.stringify({
        locked: root.locked,
        requested: root.lockRequested,
        pending: root.pendingSessionLock,
        sessionLocked: sessionLock.locked,
        secure: sessionLock.secure,
        realScreens: root.realScreenCount(),
        passwordPam: root.passwordPamConfigured,
        fingerprint: root.fingerprintConfigured,
        face: root.faceConfigured,
        faceAuthenticating: root.faceAuthenticating,
        faceAutoAttempts: root.faceAutoAttempts,
        faceStatus: root.faceStatus,
        authenticating: root.authenticating,
        lastEvent: root.lastEvent,
        lastEventAt: root.lastEventAt
      })
    }

    function preview(): string {
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.refreshFaceStatus()
      root.previewVisible = true
      return "ok"
    }

    function hidePreview(): string {
      root.previewVisible = false
      return "ok"
    }
  }
}
