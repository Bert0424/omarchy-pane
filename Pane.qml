import QtQuick
import QtQuick.Particles
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Weather on the inside of the glass. One transparent, fully click-through
// layer-shell surface per screen, carrying four independent layers:
//
//   1. streaks — falling rain/snow, GPU particles (QtQuick.Particles)
//   2. beads   — droplets clinging to the glass that dwell, merge with each
//                other, then run down leaving a fading trail; a fixed pool
//                that recycles itself
//   3. fog     — a soft haze creeping in from the screen edges
//   4. flash   — lightning: a drawn bolt plus a directional full-screen flash
//
// Note we cannot refract what is behind the surface: a Wayland layer surface
// has no read access to the composited framebuffer beneath it. So the beads
// are painted light — rim, highlight and trail — rather than true distortion.
// It reads convincingly and costs nothing.
//
// When there is no weather the PanelWindow is left unmapped, so a dry day is
// genuinely free rather than a transparent fullscreen surface the compositor
// has to blend every frame. Turning the weather off does not cut instantly:
// the pane dries off first (see `drying`) and only then unmaps.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // --- live config, pushed from BarWidget.applyConfig ------------------
  property bool showWeather: true
  property string conditions: "Rain"        // Drizzle | Rain | Downpour | Thunderstorm | Snow
  property string stackLayer: "top"         // top | bottom | overlay
  property real densityScale: 1.0
  property bool wantStreaks: true
  property bool wantBeads: true
  property bool wantLightning: true
  property bool wantFog: false
  property real windAngle: 0                // degrees off vertical
  property real windVariation: 1

  // Pause outright while something is fullscreen (a game, a video). The
  // surface is unmapped rather than hidden, so the effect costs nothing
  // at exactly the moment you least want it running.
  property bool pauseOnFullscreen: true
  property bool fullscreenActive: false

  readonly property bool isSnow: conditions === "Snow"
  readonly property bool isStorm: conditions === "Thunderstorm"

  // --- wet / drying / dry ----------------------------------------------
  // wetIntent is "it should be weathering right now". When it goes false we
  // do NOT unmap: beads shrink and evaporate over dryDurationMs first, which
  // is the whole difference between weather stopping and a window closing.
  // A fullscreen pause is the one case that still cuts immediately — the
  // point of that path is to stop spending frames at once.
  property int dryDurationMs: 90000
  property bool drying: false
  property bool everWet: false

  readonly property bool wetIntent: showWeather && (wantStreaks || wantBeads || wantFog)
  readonly property bool surfaceUp: (wetIntent || drying)
                                    && !(pauseOnFullscreen && fullscreenActive)

  // Any moment the surface is actually mapped counts as having been wet.
  // Deriving this from wetIntent alone missed the startup case, where
  // wetIntent is true before anything can observe it change.
  onSurfaceUpChanged: if (surfaceUp) everWet = true

  onWetIntentChanged: {
    if (wetIntent) {
      drying = false
      dryTimer.stop()
      everWet = true
    } else if (everWet) {
      drying = true
      dryTimer.restart()
    }
  }

  Timer {
    id: dryTimer
    interval: root.dryDurationMs
    repeat: false
    onTriggered: root.drying = false
  }

  // Fired once per strike, at root level so every screen lights together —
  // a per-window timer gave each monitor its own private storm.
  signal strike(real norm)

  function applyConfig(s) {
    if (!s) return
    if (typeof s.enabled === "boolean") showWeather = s.enabled
    if (typeof s.streaks === "boolean") wantStreaks = s.streaks
    if (typeof s.beads === "boolean") wantBeads = s.beads
    if (typeof s.lightning === "boolean") wantLightning = s.lightning
    if (typeof s.fog === "boolean") wantFog = s.fog
    if (typeof s.pauseFullscreen === "boolean") pauseOnFullscreen = s.pauseFullscreen
    if (typeof s.intensity === "string") conditions = s.intensity
    stackLayer = s.layer === "On the desktop" ? "bottom"
               : s.layer === "Above everything" ? "overlay" : "top"
    densityScale = s.density === "Sparse" ? 0.5 : s.density === "Heavy" ? 1.8 : 1.0
    // Keep the variation tight: real rain falls as a coherent sheet, and
    // per-streak angle scatter reads as mess rather than turbulence.
    if (s.wind === "Light")      { windAngle = 5;  windVariation = 2 }
    else if (s.wind === "Gusty") { windAngle = 16; windVariation = 6 }
    else                         { windAngle = 0;  windVariation = 1 }
  }

  // --- condition presets ------------------------------------------------
  // emitRate is per-screen and already density-scaled at the call site.
  readonly property var preset: ({
    "Drizzle":      { rate: 40,  life: 2600, speed: 620,  len: [7, 14],  thick: 1.0, alpha: 0.26, beads: 14, bead: [3, 7] },
    "Rain":         { rate: 120, life: 2000, speed: 1000, len: [13, 26], thick: 1.3, alpha: 0.34, beads: 26, bead: [4, 10] },
    "Downpour":     { rate: 300, life: 1500, speed: 1500, len: [20, 40], thick: 1.6, alpha: 0.42, beads: 44, bead: [5, 13] },
    "Thunderstorm": { rate: 330, life: 1400, speed: 1650, len: [24, 46], thick: 1.7, alpha: 0.46, beads: 50, bead: [5, 14] },
    "Snow":         { rate: 70, life: 9000, speed: 90,   len: [3, 7],   thick: 3.0, alpha: 0.72, beads: 0,  bead: [0, 0] }
  })
  readonly property var p: preset[conditions] || preset["Rain"]

  // A merged bead can outgrow its preset, but not without limit — past this
  // it stops reading as a droplet and starts reading as a blob.
  readonly property real maxBead: p.bead[1] * 2.4

  function rand(a, b) { return a + Math.random() * (b - a) }
  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  Socket {
    id: hyprEvents
    connected: root.showWeather && root.pauseOnFullscreen
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/hypr/"
          + Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") + "/.socket2.sock"
    parser: SplitParser {
      onRead: function (line) {
        if (line.indexOf("fullscreen>>") === 0)
          root.fullscreenActive = line.substring(12).trim() === "1"
      }
    }
  }

  // Storm clock. Lives here, not per-window, so all screens flash together.
  Timer {
    id: stormClock
    running: root.surfaceUp && root.isStorm && root.wantLightning && root.wetIntent
    repeat: true
    interval: 6000
    onTriggered: {
      if (Math.random() < 0.45) root.strike(Math.random())
      interval = Math.round(root.rand(4000, 17000))
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData
      // Unmapped entirely when there is no weather — costs nothing when dry.
      visible: root.surfaceUp

      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore

      WlrLayershell.namespace: "bert-pane"
      WlrLayershell.layer: root.stackLayer === "overlay" ? WlrLayer.Overlay
                         : root.stackLayer === "bottom"  ? WlrLayer.Bottom
                         : WlrLayer.Top
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      // Empty region: every click, drag and hover passes straight through.
      mask: Region {}

      // Channels worn into the glass by beads that have already run. New
      // beads prefer them, so rivulets form and persist instead of every
      // drop carving its own path.
      property var tracks: []
      function noteTrack(cx) {
        var t = tracks.slice(-5)
        t.push(cx)
        tracks = t
      }
      function pickX(size) {
        var span = Math.max(1, win.width - size)
        if (tracks.length && Math.random() < 0.45) {
          var c = tracks[Math.floor(Math.random() * tracks.length)]
          return root.clamp(c - size / 2 + root.rand(-9, 9), 0, span)
        }
        return root.rand(0, span)
      }

      // ---------------------------------------------------------------
      // 1. Falling rain / snow
      // ---------------------------------------------------------------
      ParticleSystem {
        id: sys
        // Kept running through the drying phase so streaks already in the
        // air finish their fall instead of blinking out mid-screen.
        running: root.surfaceUp && root.wantStreaks
        paused: !win.visible
      }

      Emitter {
        system: sys
        enabled: root.surfaceUp && root.wantStreaks && root.wetIntent
        // Emit from a band above the top edge so streaks are already at
        // full speed by the time they cross into view.
        width: win.width * 1.4
        height: 10
        x: -win.width * 0.2
        y: -30
        emitRate: Math.round(root.p.rate * root.densityScale)
        lifeSpan: root.p.life
        lifeSpanVariation: Math.round(root.p.life * 0.25)
        size: root.isSnow ? 7 : (root.p.len[0] + root.p.len[1]) / 2
        sizeVariation: root.isSnow ? 5 : (root.p.len[1] - root.p.len[0]) / 2
        velocity: AngleDirection {
          // 90 deg is straight down in particle space; wind tilts it.
          angle: 90 - root.windAngle
          angleVariation: root.windVariation
          magnitude: root.p.speed
          magnitudeVariation: root.p.speed * 0.22
        }
        acceleration: AngleDirection {
          angle: 90
          magnitude: root.isSnow ? 6 : 240      // snow drifts, rain accelerates
        }
      }

      // Snow wanders sideways; rain does not.
      Wander {
        system: sys
        enabled: root.isSnow && root.surfaceUp && root.wantStreaks
        xVariance: 42
        pace: 22
      }

      // ImageParticle, not ItemParticle: this is a batched GPU quad per
      // particle rather than a live QML item. At Thunderstorm/Heavy there are
      // ~1700 particles alive at once, and instantiating that many items cost
      // ~80% of a core. The elongation of a streak lives inside the sprite,
      // since ImageParticle always draws into a square size x size quad.
      ImageParticle {
        system: sys
        source: root.isSnow ? Qt.resolvedUrl("assets/flake.png")
                            : Qt.resolvedUrl("assets/streak.png")
        color: Qt.rgba(0.86, 0.93, 1.0, root.p.alpha)
        colorVariation: 0.05
        alphaVariation: root.p.alpha * 0.45
        // Rain leans into its own travel; flakes stay upright.
        autoRotation: !root.isSnow
      }

      // ---------------------------------------------------------------
      // 2. Beads on the glass
      //
      // A fixed pool that recycles: each bead picks a spot, fades in, clings,
      // then runs down trailing a fading streak, then respawns somewhere new.
      // No model churn, so the item count is constant and the scene graph
      // stays batched.
      //
      // Beads that touch merge, conserving area. A merged bead is heavier
      // than either parent, so it stops clinging and runs — and it keeps
      // absorbing whatever it passes on the way down. That is what produces
      // rivulets rather than a field of independent dots.
      // ---------------------------------------------------------------
      Timer {
        // n <= 50, so an all-pairs sweep is ~1200 comparisons a tick. That is
        // far cheaper than any spatial index would be to maintain here.
        running: win.visible && root.wantBeads && !root.isSnow && !root.drying
        repeat: true
        interval: 220
        onTriggered: win.mergePass()
      }

      // Beads merge for two different reasons, and one point-in-time overlap
      // test gets both of them wrong.
      //
      // A running bead is the interesting case. At a 220ms tick a fast one
      // covers ~170px while the overlap window is ~10px wide, so a plain
      // position check tunnels straight past roughly nine tenths of what it
      // passes. Runners therefore test the whole segment they just travelled,
      // and may absorb several beads in a single tick — which is the entire
      // point of a rivulet.
      //
      // Two dwelling beads, by contrast, never move toward each other at all.
      // They merge only because one of them grew into the other, which is what
      // accretion is for: a clinging bead catches falling drops and slowly
      // gains size, exactly as it does on real glass.
      function mergePass() {
        var n = beadPool.count
        var i, j, a, b

        // 1. runners sweep the path they travelled since the last tick
        for (i = 0; i < n; i++) {
          a = beadPool.itemAt(i)
          if (!a || !a.mergeable || a.phase !== "run") continue
          var lo = Math.min(a.prevCy, a.cy)
          var hi = Math.max(a.prevCy, a.cy)
          var grew = false
          for (j = 0; j < n; j++) {
            if (j === i) continue
            b = beadPool.itemAt(j)
            // Runner-into-runner is deliberately excluded: two beads absorbing
            // each other in the same tick is a knot of special cases for an
            // effect nobody would notice.
            if (!b || !b.mergeable || b.phase === "run") continue
            var reach = a.radius + b.radius
            if (Math.abs(b.cx - a.cx) > reach) continue
            if (b.cy < lo - reach || b.cy > hi + reach) continue
            a.absorbSize(b.bsize)
            b.respawn()
            grew = true
          }
          // Re-derive the fall from the new weight once, not once per victim.
          if (grew) a.beginRun()
        }

        // 2. dwellers that have grown into one another
        for (i = 0; i < n; i++) {
          a = beadPool.itemAt(i)
          if (!a || !a.mergeable || a.phase !== "dwell") continue
          for (j = i + 1; j < n; j++) {
            b = beadPool.itemAt(j)
            if (!b || !b.mergeable || b.phase !== "dwell") continue
            var dx = a.cx - b.cx
            var dy = a.cy - b.cy
            // 0.92 so they visibly touch before merging rather than snapping
            // together across a gap.
            if (dx * dx + dy * dy > Math.pow((a.radius + b.radius) * 0.92, 2)) continue
            var big = a.bsize >= b.bsize ? a : b
            var small = (big === a) ? b : a
            big.absorbSize(small.bsize)
            small.respawn()
            big.beginRun()   // newly heavy: it stops clinging
            break
          }
        }

        // 3. accretion, then remember where everything was for the next sweep
        for (i = 0; i < n; i++) {
          a = beadPool.itemAt(i)
          if (!a) continue
          if (a.phase === "dwell" && root.wetIntent
              && Math.random() < 0.06 * root.densityScale)
            a.accrete()
          a.prevCy = a.cy
        }
      }

      Repeater {
        id: beadPool
        model: root.wantBeads && !root.isSnow
               ? Math.round(root.p.beads * root.densityScale) : 0

        delegate: Item {
          id: bead

          property real bsize: 6
          property real startY: 0
          property real travel: 0        // px fallen so far — drives the trail
          property string phase: "spawn" // spawn | dwell | run | drying | gone
          property real prevCy: 0        // where this bead was last tick — the
                                         // far end of the segment a runner sweeps

          readonly property real radius: bsize / 2
          readonly property real cx: x + bsize / 2
          readonly property real cy: y + (bsize * 1.3) / 2
          // Only settled, visible beads take part in merging — a bead still
          // fading in or already evaporating should not grab its neighbours.
          readonly property bool mergeable: (phase === "dwell" || phase === "run")
                                            && opacity > 0.6

          width: bsize
          height: bsize * 1.3
          y: startY + travel
          opacity: 0

          function heaviness() {
            var lo = root.p.bead[0]
            var hi = Math.max(lo + 0.01, root.p.bead[1])
            return root.clamp((bsize - lo) / (hi - lo), 0, 1.6)
          }

          function park() {
            fadeIn.stop(); runAnim.stop(); fadeOut.stop(); evaporate.stop(); dwell.stop()
            phase = "gone"
            opacity = 0
          }

          function respawn() {
            fadeIn.stop(); runAnim.stop(); fadeOut.stop(); evaporate.stop(); dwell.stop()
            // Nothing animates while the pane is down: an unmapped surface
            // still runs its animations, and that is exactly the cost the
            // unmapped-when-dry design exists to avoid.
            if (root.drying || !root.surfaceUp) { phase = "gone"; opacity = 0; return }
            phase = "spawn"
            bsize = root.rand(root.p.bead[0], root.p.bead[1])
            x = win.pickX(bsize)
            startY = root.rand(-20, win.height * 0.8)
            travel = 0
            prevCy = startY + (bsize * 1.3) / 2
            opacity = 0
            fadeIn.restart()
          }

          // Absorb another bead's volume. Area adds, so radii add in
          // quadrature — a merged bead grows far less than doubling, which
          // is what keeps this from snowballing into one giant blob.
          // Growing does not restart the fall; the caller does that once it
          // has finished absorbing everything in reach this tick.
          function absorbSize(otherSize) {
            bsize = Math.min(root.maxBead, Math.sqrt(bsize * bsize + otherSize * otherSize))
          }

          // A clinging bead catching falling drops. Small and frequent rather
          // than rare and large, so beads drift into contact instead of
          // jumping into it — and so a long-clinging bead eventually gets
          // heavy enough to go on its own.
          function accrete() {
            bsize = Math.min(root.maxBead, bsize + root.rand(0.12, 0.45))
          }

          function beginRun() {
            dwell.stop(); runAnim.stop()
            phase = "run"
            var remaining = win.height + 40 - (startY + travel)
            if (remaining <= 0) { fadeOut.restart(); return }
            runAnim.from = travel
            runAnim.to = travel + remaining
            runAnim.duration = Math.max(260, Math.round(remaining / (150 + heaviness() * 620) * 1000))
            runAnim.restart()
            win.noteTrack(cx)
          }

          // The pane drying off: stop clinging forever, let a few take one
          // last slide, and evaporate the rest on a stagger so they don't
          // all vanish on the same frame.
          function dryOff() {
            dwell.stop()
            phase = "drying"
            if (Math.random() < 0.3 && travel < win.height) beginRun()
            evaporate.duration = Math.round(root.rand(1500, root.dryDurationMs * 0.75))
            evaporate.targetSize = Math.max(1, bsize * 0.25)
            evaporate.restart()
          }

          Component.onCompleted: {
            // Stagger the pool so they do not all arrive on the same beat.
            stagger.interval = Math.round(Math.random() * 6000)
            stagger.start()
          }
          Timer { id: stagger; repeat: false; onTriggered: bead.respawn() }

          Connections {
            target: root
            function onDryingChanged() {
              if (root.drying) bead.dryOff()
              else if (root.surfaceUp) bead.respawn()
              else bead.park()
            }
            function onSurfaceUpChanged() {
              if (root.surfaceUp) bead.respawn()
              else bead.park()
            }
          }

          NumberAnimation {
            id: fadeIn
            target: bead; property: "opacity"; to: 1; duration: 420
            onFinished: {
              if (bead.phase !== "spawn") return
              bead.phase = "dwell"
              // Bigger beads are heavier: they cling less.
              dwell.interval = Math.round(root.rand(600, 9000) * (1.25 - bead.heaviness()))
              dwell.restart()
            }
          }

          Timer { id: dwell; repeat: false; onTriggered: bead.beginRun() }

          NumberAnimation {
            id: runAnim
            target: bead; property: "travel"
            easing.type: Easing.InQuad      // accelerates as it runs
            onFinished: if (bead.phase === "run") fadeOut.restart()
          }

          NumberAnimation {
            id: fadeOut
            target: bead; property: "opacity"; to: 0; duration: 200
            onFinished: bead.respawn()
          }

          ParallelAnimation {
            id: evaporate
            property int duration: 4000
            property real targetSize: 1
            NumberAnimation {
              target: bead; property: "opacity"; to: 0
              duration: evaporate.duration; easing.type: Easing.InCubic
            }
            NumberAnimation {
              target: bead; property: "bsize"; to: evaporate.targetSize
              duration: evaporate.duration; easing.type: Easing.InCubic
            }
            onFinished: bead.phase = "gone"
          }

          // Trail left on the glass above the bead, brightest just behind it.
          Rectangle {
            width: Math.max(1, bead.bsize * 0.42)
            height: Math.min(bead.travel, 150)
            anchors.horizontalCenter: parent.horizontalCenter
            y: -height
            visible: height > 1
            gradient: Gradient {
              GradientStop { position: 0.0; color: Qt.rgba(0.85, 0.93, 1.0, 0.0) }
              GradientStop { position: 1.0; color: Qt.rgba(0.85, 0.93, 1.0, 0.15) }
            }
          }

          // The bead body: dark rim up top, bright pool at the bottom, which
          // is what sells "water on glass" without any real refraction.
          Rectangle {
            anchors.fill: parent
            radius: width / 2
            antialiasing: true
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.30)
            gradient: Gradient {
              GradientStop { position: 0.0; color: Qt.rgba(0.55, 0.65, 0.78, 0.16) }
              GradientStop { position: 0.7; color: Qt.rgba(0.88, 0.95, 1.00, 0.30) }
              GradientStop { position: 1.0; color: Qt.rgba(1.00, 1.00, 1.00, 0.46) }
            }
          }

          // Specular pin-prick, up and to the left, like a light source.
          Rectangle {
            width: Math.max(1, bead.bsize * 0.26)
            height: width
            radius: width / 2
            antialiasing: true
            x: bead.bsize * 0.24
            y: bead.bsize * 0.22
            color: Qt.rgba(1, 1, 1, 0.75)
          }
        }
      }

      // ---------------------------------------------------------------
      // 3. Fog
      //
      // Deliberately an edge effect, not a full-screen wash: haze creeping in
      // from the borders leaves the middle of the screen at full contrast,
      // which is the only reason a permanent overlay is tolerable to work
      // under. Four gradients, no blur, no shader — it is four quads.
      // ---------------------------------------------------------------
      Item {
        id: fogLayer
        anchors.fill: parent
        visible: root.wantFog && opacity > 0.01
        opacity: root.drying ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 9000; easing.type: Easing.InOutQuad } }

        // Fog is never still. Two out-of-phase breaths keep the edges from
        // pulsing in unison, which would read as a fade rather than weather.
        property real breathA: 1
        property real breathB: 1
        readonly property real base: 0.13

        SequentialAnimation on breathA {
          running: fogLayer.visible; loops: Animation.Infinite
          NumberAnimation { to: 1.35; duration: 13000; easing.type: Easing.InOutSine }
          NumberAnimation { to: 0.70; duration: 17000; easing.type: Easing.InOutSine }
        }
        SequentialAnimation on breathB {
          running: fogLayer.visible; loops: Animation.Infinite
          NumberAnimation { to: 0.72; duration: 19000; easing.type: Easing.InOutSine }
          NumberAnimation { to: 1.28; duration: 11000; easing.type: Easing.InOutSine }
        }

        function haze(mult) {
          return Qt.rgba(0.88, 0.92, 0.97, Math.min(0.3, fogLayer.base * mult))
        }

        Rectangle {
          width: parent.width; height: parent.height * 0.30
          anchors.top: parent.top
          gradient: Gradient {
            GradientStop { position: 0.0; color: fogLayer.haze(fogLayer.breathA) }
            GradientStop { position: 1.0; color: Qt.rgba(0.88, 0.92, 0.97, 0) }
          }
        }
        Rectangle {
          width: parent.width; height: parent.height * 0.34
          anchors.bottom: parent.bottom
          gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(0.88, 0.92, 0.97, 0) }
            GradientStop { position: 1.0; color: fogLayer.haze(fogLayer.breathB * 1.15) }
          }
        }
        Rectangle {
          width: parent.width * 0.22; height: parent.height
          anchors.left: parent.left
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: fogLayer.haze(fogLayer.breathB) }
            GradientStop { position: 1.0; color: Qt.rgba(0.88, 0.92, 0.97, 0) }
          }
        }
        Rectangle {
          width: parent.width * 0.22; height: parent.height
          anchors.right: parent.right
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(0.88, 0.92, 0.97, 0) }
            GradientStop { position: 1.0; color: fogLayer.haze(fogLayer.breathA) }
          }
        }
      }

      // ---------------------------------------------------------------
      // 4. Lightning — a drawn bolt, plus a flash weighted toward it
      // ---------------------------------------------------------------
      Connections {
        target: root
        function onStrike(norm) {
          if (!win.visible) return
          flashPane.fire(norm)
          if (boltLoader.item) boltLoader.item.fire(norm)
        }
      }

      Rectangle {
        id: flashPane
        anchors.fill: parent
        opacity: 0
        visible: opacity > 0

        // Where on the screen the strike landed, 0..1. The flash is brighter
        // on that side — a storm lighting the room from one direction reads
        // far more real than a uniform white wash, for the same cost.
        property real norm: 0.5
        readonly property real midPos: root.clamp(norm, 0.06, 0.94)
        function sideAlpha(pos) { return Math.max(0.16, 1 - Math.abs(pos - norm) * 1.15) }

        function fire(n) { norm = n; flash.restart() }

        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, flashPane.sideAlpha(0.0)) }
          GradientStop { position: flashPane.midPos; color: Qt.rgba(1, 1, 1, 1) }
          GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, flashPane.sideAlpha(1.0)) }
        }

        SequentialAnimation {
          id: flash
          // Double-strike: sharp leader, gap, weaker return stroke.
          // Target flashPane explicitly: inside an animation `parent` resolves
          // from the enclosing scope (this Rectangle's parent, i.e. the window
          // content item), not to the Rectangle, so it silently animated the
          // whole scene's opacity and the flash never showed.
          NumberAnimation { target: flashPane; property: "opacity"; to: 0.50; duration: 45 }
          NumberAnimation { target: flashPane; property: "opacity"; to: 0.05; duration: 90 }
          NumberAnimation { target: flashPane; property: "opacity"; to: 0.30; duration: 60 }
          NumberAnimation { target: flashPane; property: "opacity"; to: 0.0;  duration: 420 }
        }
      }

      // Only instantiated during a storm — a fullscreen Canvas holds a
      // texture the size of the screen, so it should not exist on a clear day.
      Loader {
        id: boltLoader
        anchors.fill: parent
        active: root.surfaceUp && root.isStorm && root.wantLightning

        sourceComponent: Canvas {
          id: bolt
          opacity: 0
          visible: opacity > 0
          renderStrategy: Canvas.Threaded

          property var strokes: []

          // Midpoint displacement: start with a line, repeatedly split each
          // segment and jitter the new point by a shrinking amount. Five
          // passes gives 33 points, which is plenty of kink at screen size.
          function jaggedPath(x0, y0, x1, y1, spread) {
            var pts = [{ x: x0, y: y0 }, { x: x1, y: y1 }]
            for (var pass = 0; pass < 5; pass++) {
              var next = []
              var amp = spread * Math.pow(0.58, pass)
              for (var i = 0; i < pts.length - 1; i++) {
                var a = pts[i], b = pts[i + 1]
                next.push(a)
                next.push({
                  x: (a.x + b.x) / 2 + (Math.random() - 0.5) * amp,
                  y: (a.y + b.y) / 2 + (Math.random() - 0.5) * amp * 0.22
                })
              }
              next.push(pts[pts.length - 1])
              pts = next
            }
            return pts
          }

          function fire(n) {
            var x0 = n * width
            var endY = height * root.rand(0.55, 1.0)
            var main = jaggedPath(x0, -10, x0 + root.rand(-width * 0.16, width * 0.16),
                                  endY, width * 0.10)
            var out = [{ pts: main, w: 1.0 }]

            // One or two forks, branching off the upper half and dying early.
            var forks = 1 + (Math.random() < 0.55 ? 1 : 0)
            for (var f = 0; f < forks; f++) {
              var at = Math.floor(root.rand(main.length * 0.2, main.length * 0.65))
              var from = main[at]
              out.push({
                pts: jaggedPath(from.x, from.y,
                                from.x + root.rand(-width * 0.13, width * 0.13),
                                from.y + root.rand(height * 0.12, height * 0.3),
                                width * 0.05),
                w: 0.55
              })
            }
            strokes = out
            requestPaint()
            strikeAnim.restart()
          }

          onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            if (!strokes || !strokes.length) return
            ctx.lineCap = "round"
            ctx.lineJoin = "round"

            for (var s = 0; s < strokes.length; s++) {
              var st = strokes[s]
              // Halo first, then the core over it — two passes is what makes
              // a stroke look like it is emitting light rather than drawn.
              for (var layer = 0; layer < 2; layer++) {
                ctx.beginPath()
                ctx.moveTo(st.pts[0].x, st.pts[0].y)
                for (var i = 1; i < st.pts.length; i++) ctx.lineTo(st.pts[i].x, st.pts[i].y)
                if (layer === 0) {
                  ctx.strokeStyle = Qt.rgba(0.62, 0.78, 1.0, 0.28)
                  ctx.lineWidth = 9 * st.w
                } else {
                  ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.95)
                  ctx.lineWidth = 2.1 * st.w
                }
                ctx.stroke()
              }
            }
          }

          // Visible for a couple of hundred milliseconds, flickering once —
          // roughly the shape of a real return stroke.
          SequentialAnimation {
            id: strikeAnim
            NumberAnimation { target: bolt; property: "opacity"; to: 1.0; duration: 25 }
            NumberAnimation { target: bolt; property: "opacity"; to: 0.25; duration: 55 }
            NumberAnimation { target: bolt; property: "opacity"; to: 0.9; duration: 35 }
            NumberAnimation { target: bolt; property: "opacity"; to: 0.0; duration: 240
                              easing.type: Easing.OutQuad }
          }
        }
      }
    }
  }
}
