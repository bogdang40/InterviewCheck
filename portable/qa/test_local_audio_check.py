"""Optional audio checks retain neither a stream nor an upload after cancellation."""

import re
from playwright.sync_api import expect


def test_late_permission_and_pagehide_release_all_tracks(workspace_url, browser_page):
    page = browser_page
    page.add_init_script("""
        const realCapture=navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
        window.qaTracks=[];window.qaContexts=[];window.qaRequests=0;
        const Context=window.AudioContext;
        window.AudioContext=class extends Context {
            constructor(...args){super(...args);window.qaContexts.push(this);}
        };
        navigator.mediaDevices.getDisplayMedia=() => {
            window.qaRequests++;
            return new Promise(resolve => {
                window.qaGrant=async () => {
                    const audioStream=await realCapture({audio:true});
                    const frame=document.createElement("canvas");
                    frame.width=frame.height=4;
                    const video=frame.captureStream(10).getVideoTracks()[0];
                    const stream=new MediaStream([...audioStream.getAudioTracks(), video]);
                    window.qaTracks=stream.getTracks();resolve(stream);
                };
            });
        };
    """)
    outgoing = []
    page.on("request", lambda r: outgoing.append(r.url) if r.method not in ("GET", "HEAD") else None)
    page.goto(workspace_url + "/interviews/new/")
    page.get_by_text("Audio preflight", exact=True).click()
    assert page.evaluate("qaRequests") == 0
    start = page.get_by_role("button", name="Test shared call audio")
    start.click()
    page.get_by_role("button", name="Stop audio check").click()
    page.evaluate("qaGrant()")
    page.wait_for_function("() => qaTracks.length===2 && qaTracks.every(t=>t.readyState==='ended')")
    page.wait_for_function("() => qaContexts.every(c=>c.state==='closed')")
    start.click()
    page.evaluate("qaGrant()")
    expect(page.get_by_role("meter")).to_be_visible()
    page.evaluate("window.dispatchEvent(new Event('pagehide'))")
    page.wait_for_function(
        "() => qaContexts.length>0 && qaContexts.every(c=>c.state==='closed') && qaTracks.every(t=>t.readyState==='ended')"
    )
    assert not outgoing


def test_silent_input_is_distinguished_from_permission_denial(workspace_url, browser_page):
    page = browser_page
    page.add_init_script("""
        const Context=window.AudioContext;window.sourceAudio=null;
        navigator.mediaDevices.getUserMedia=async () => {
            window.sourceAudio=new Context(); await sourceAudio.resume();
            const node=sourceAudio.createMediaStreamDestination();
            window.silentTracks=node.stream.getTracks();return node.stream;
        };
        navigator.mediaDevices.getDisplayMedia=async () => {throw new DOMException('fixture', 'NotAllowedError');};
    """)
    page.goto(workspace_url + "/connections/")
    page.get_by_text("Audio preflight", exact=True).click()
    page.get_by_role("button", name="Test microphone").click()
    expect(page.get_by_role("status").filter(has_text=re.compile("No signal measured"))).to_be_visible(
        timeout=8000
    )
    assert page.evaluate("silentTracks.every(t=>t.readyState==='ended')")
    page.evaluate("sourceAudio.close()")
    page.get_by_role("button", name="Test shared call audio").click()
    expect(page.get_by_role("status").filter(has_text="Permission was denied")).to_be_visible()
