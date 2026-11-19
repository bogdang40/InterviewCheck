"""Local audio preflight through Chromium's real analyser with generated input."""

from playwright.sync_api import expect

DEVICES = """
(() => {
  const Native = window.AudioContext;
  const devices = window.testInputs = {mode:"tone", requests:[], checks:[], tracks:[], generators:[], encodes:0};
  window.AudioContext = class extends Native {
    constructor(...args) { super(...args); devices.checks.push(this); }
  };
  window.MediaRecorder = class {constructor(){devices.encodes++;throw Error("Unexpected recording");}};
  async function input(source) {
    devices.requests.push(source);
    if (devices.mode === "deny") throw new DOMException("Test denied", "NotAllowedError");
    const tracks = [];
    if (source === "shared") {
      const frame = document.createElement("canvas");
      frame.width = frame.height = 4;
      const video = frame.captureStream(10).getVideoTracks()[0]; tracks.push(video);
    }
    if (devices.mode !== "missing") {
      const context = new Native();
      devices.generators.push(context);
      const osc = context.createOscillator(), level = context.createGain();
      level.gain.value = devices.mode === "silent" ? 0 : .25;
      const output = context.createMediaStreamDestination();
      osc.connect(level).connect(output); osc.start();
      await context.resume();
      tracks.push(...output.stream.getAudioTracks());
    }
    devices.tracks.push(...tracks);
    const stream = new MediaStream(tracks);
    if (devices.mode === "late") return new Promise(resolve => devices.release = () => resolve(stream));
    return stream;
  }
  navigator.mediaDevices.getUserMedia = () => input("microphone");
  navigator.mediaDevices.getDisplayMedia = () => input("shared");
})();
"""


def install(page, base, suffix):
    page.add_init_script(DEVICES)
    page.goto(base + suffix)
    page.get_by_text("Audio preflight", exact=True).click()
    assert page.evaluate("testInputs.requests.length") == 0
    assert page.evaluate("testInputs.checks.length") == 0


def stopped(page):
    page.wait_for_function("""() => testInputs.tracks.every(t => t.readyState === 'ended') &&
                               testInputs.checks.every(c => c.state === 'closed')""")
    assert page.evaluate("testInputs.encodes") == 0


def test_preflight_measures_actual_waveform_and_silence(workspace_url, browser_page, tmp_path):
    page = browser_page
    install(page, workspace_url, "/interviews/new/")
    writes = []
    page.on(
        "request",
        lambda req: writes.append(req.url) if req.method in ("POST", "PUT", "PATCH", "DELETE") else None,
    )
    page.get_by_role("button", name="Test microphone").click()
    expect(page.get_by_role("meter", name="Input level in dBFS")).to_be_visible()
    expect(page.get_by_text("Signal detected. Peak measured level", exact=False)).to_be_visible(timeout=7000)
    stopped(page)
    page.get_by_text("Audio preflight", exact=True).locator("..").screenshot(
        path=tmp_path / "audio-preflight.png"
    )
    page.evaluate("testInputs.mode='silent'")
    page.get_by_role("button", name="Test shared call audio").click()
    expect(page.get_by_text("No signal measured during the check.", exact=False)).to_be_visible(timeout=7000)
    stopped(page)
    assert page.evaluate("testInputs.requests") == ["microphone", "shared"]
    assert page.evaluate("testInputs.tracks.map(t=>t.kind)") == ["audio", "video", "audio"]
    assert not writes


def test_preflight_denied_missing_audio_and_late_grant(workspace_url, browser_page):
    page = browser_page
    install(page, workspace_url, "/connections/")
    page.evaluate("testInputs.mode='deny'")
    page.get_by_role("button", name="Test microphone").click()
    expect(page.get_by_text("Permission was denied", exact=False)).to_be_visible()
    stopped(page)
    page.evaluate("testInputs.mode='missing'")
    page.get_by_role("button", name="Test shared call audio").click()
    expect(page.get_by_text("No audio track was shared.", exact=False)).to_be_visible()
    stopped(page)
    page.evaluate("testInputs.mode='late'")
    page.get_by_role("button", name="Test shared call audio").click()
    page.wait_for_function("() => typeof testInputs.release === 'function'")
    page.get_by_role("button", name="Stop audio check").click()
    page.evaluate("testInputs.release()")
    stopped(page)
    expect(page.get_by_text("Audio check stopped.", exact=True)).to_be_visible()
    expect(page.get_by_role("meter")).to_have_count(0)


def test_picker_end_and_hidden_tab_stop_all_tracks(workspace_url, browser_page):
    page = browser_page
    install(page, workspace_url, "/connections/")
    page.get_by_role("button", name="Test shared call audio").click()
    expect(page.get_by_role("meter")).to_be_visible()
    page.evaluate("testInputs.tracks.find(t=>t.kind==='video').dispatchEvent(new Event('ended'))")
    expect(page.get_by_text("The selected input ended.", exact=False)).to_be_visible()
    stopped(page)
    page.get_by_role("button", name="Test microphone").click()
    expect(page.get_by_role("meter")).to_be_visible()
    page.evaluate("""() => { Object.defineProperty(document, 'hidden', {configurable:true, value:true});
                               document.dispatchEvent(new Event('visibilitychange')); }""")
    expect(page.get_by_text("Audio check stopped when the tab was hidden.")).to_be_visible()
    stopped(page)
