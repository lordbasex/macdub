// Runs in Meet's own page (MAIN world): while MacDub translates with "send as audio", what Meet
// sends is the virtual microphone (BlackHole) whatever microphone is chosen in Meet, and Meet's
// own microphone comes back when MacDub stops. Meet's mute is always respected.
// content.js turns it on and off through <html data-macdub-mic="on">.
(() => {
  const VIRTUAL = /blackhole/i;
  const md = navigator.mediaDevices;
  const wanted = () => document.documentElement.dataset.macdubMic === 'on';
  const log = (...a) => console.log('[MacDub]', ...a);

  // Every sender Meet uses, with the track Meet itself wants on it.
  const meetTrack = new Map();   // RTCRtpSender → MediaStreamTrack | null
  let virtual = null;            // the BlackHole track while in use

  async function virtualTrack() {
    if (virtual && virtual.readyState === 'live') return virtual;
    const devices = await md.enumerateDevices();
    const device = devices.find(d => d.kind === 'audioinput' && VIRTUAL.test(d.label));
    if (!device) { log('virtual microphone not found among', devices.filter(d => d.kind === 'audioinput').map(d => d.label)); return null; }
    const stream = await getUserMedia.call(md, { audio: {
      deviceId: { exact: device.deviceId }, echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
    virtual = stream.getAudioTracks()[0];
    log('virtual microphone opened:', device.label);
    return virtual;
  }

  // Meet opening a microphone while MacDub is on: open the virtual one instead.
  const getUserMedia = md.getUserMedia;
  md.getUserMedia = async function (constraints) {
    if (wanted() && constraints && constraints.audio) {
      const devices = await md.enumerateDevices();
      const device = devices.find(d => d.kind === 'audioinput' && VIRTUAL.test(d.label));
      if (device) {
        const audio = typeof constraints.audio === 'object' ? constraints.audio : {};
        constraints = { ...constraints, audio: { ...audio, deviceId: { exact: device.deviceId },
          echoCancellation: false, noiseSuppression: false, autoGainControl: false } };
        log('Meet asked for a microphone: giving it', device.label);
      }
    }
    return getUserMedia.call(this, constraints);
  };

  // Meet swapping tracks (changing microphone, muting with null): remember what it wants and,
  // while MacDub is on, send the virtual microphone in its place.
  const replaceTrack = RTCRtpSender.prototype.replaceTrack;
  RTCRtpSender.prototype.replaceTrack = async function (track) {
    if (track === virtual) return replaceTrack.call(this, track);
    if (!track || track.kind === 'audio') {
      meetTrack.set(this, track);
      if (wanted() && track) return replaceTrack.call(this, (await virtualTrack()) || track);
    }
    return replaceTrack.call(this, track);
  };

  // Senders created with addTrack / addTransceiver.
  const OriginalPC = window.RTCPeerConnection;
  const connections = new Set();
  window.RTCPeerConnection = function (...args) {
    const pc = new OriginalPC(...args);
    connections.add(pc);
    return pc;
  };
  window.RTCPeerConnection.prototype = OriginalPC.prototype;
  Object.setPrototypeOf(window.RTCPeerConnection, OriginalPC);

  function audioSenders() {
    const senders = [];
    for (const pc of connections) {
      if (pc.connectionState === 'closed') { connections.delete(pc); continue; }
      for (const s of pc.getSenders()) {
        if (!meetTrack.has(s) && s.track && s.track !== virtual && s.track.kind === 'audio') meetTrack.set(s, s.track);
        if (meetTrack.has(s)) senders.push(s);
      }
    }
    return senders;
  }

  // Keep the senders in line with the switch, and the virtual track muted when Meet is muted.
  let applied = false;
  async function sync() {
    const on = wanted();
    const senders = audioSenders();
    if (on) {
      const track = await virtualTrack();
      if (!track) return;
      for (const s of senders) {
        const meet = meetTrack.get(s);
        if (meet && s.track !== track) await replaceTrack.call(s, track);
      }
      // Muted in Meet (its track disabled, or none): nothing goes out.
      const meetOn = senders.some(s => { const t = meetTrack.get(s); return t && t.enabled && t.readyState === 'live'; });
      track.enabled = meetOn;
      if (!applied) { applied = true; log('sending the virtual microphone to the call'); }
    } else if (applied) {
      for (const s of senders) {
        const meet = meetTrack.get(s);
        if (s.track !== meet) await replaceTrack.call(s, meet);
      }
      virtual?.stop();
      virtual = null;
      applied = false;
      log('back to Meet\'s own microphone');
    }
  }
  setInterval(() => sync().catch(e => log('switch failed', e.message)), 500);
})();
