#!/bin/bash
# End-to-end voice memory check with two synthetic voices: enrollment per channel, traceable
# samples, cross-channel proposal and withdrawal of one session. Uses a throwaway store and a
# random person ID; its keychain entries are removed at the end.
set -euo pipefail
cd "$(dirname "$0")/.."
model_store="${1:-$HOME/Library/Application Support/HWYD}"
app_path="${HWYD_TEST_APP:-build/How Was Your Day.app}"
helper="$app_path/Contents/Helpers/hwyd-pipeline"
mkdir -p build
fixture="$(mktemp -d "$PWD/build/voice-memory-test.XXXXXX")"
mkdir -p "$fixture/models"
cp -R "$model_store/models/diarization" "$fixture/models/diarization"
first='Bonjour tout le monde. Nous allons parler du prototype. Je propose de commencer par la capture audio et de vérifier que les deux pistes sont bien enregistrées. Ensuite nous pourrons tester la séparation des voix et préparer la prochaine démonstration pour toute notre équipe.'
second='Merci pour cette présentation. Je vais préparer les exemples pour vendredi. Il faut également vérifier la qualité des notes et garder les décisions importantes. Nous pourrons ensuite organiser une nouvelle réunion avec toute notre équipe la semaine prochaine.'
say -v Thomas -o "$fixture/first.aiff" "$first"
say -v Amélie -o "$fixture/second.aiff" "$second"
for voice in first second; do afconvert -f WAVE -d LEI16@16000 -c 1 "$fixture/$voice.aiff" "$fixture/$voice.wav"; done
person="$(uuidgen)"
cleanup() { [[ -f "$fixture/forget.json" ]] && "$helper" forget-voice "$fixture" "$fixture/forget.json" "$fixture/out.json" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Microphone: Thomas, Amélie, Thomas, Amélie. Call audio: the opposite order, so the echo
# canceller never sees the same voice on both tracks at once.
python3 - "$fixture" "$person" <<'PY'
import wave,json,uuid,pathlib,sys
p=pathlib.Path(sys.argv[1])
frames={}
for name in ('first','second'):
    with wave.open(str(p/(name+'.wav')),'rb') as w: frames[name]=w.readframes(w.getnframes())
length=max(len(v) for v in frames.values())
def track(order):
    data=b''.join(frames[n]+b'\0'*(length-len(frames[n]))+b'\0'*32000 for n in order)
    return data
for name,order in (('mic.wav',['first','second','first','second']),('system.wav',['second','first','second','first'])):
    with wave.open(str(p/name),'wb') as w:
        w.setparams((1,2,16000,0,'NONE','not compressed')); w.writeframes(track(order))
duration=len(track(['first']*4))/32000
chunks=[dict(id=str(uuid.uuid4()),source=s,relativePath=s+'.wav',start=0,duration=duration) for s in ('mic','system')]
recording=str(uuid.uuid4())
(p/'request.json').write_text(json.dumps(dict(recordingID=recording,locale='fr-FR',diarize=True,chunks=chunks)))
(p/'meta.json').write_text(json.dumps(dict(recording=recording,chunks=chunks,duration=duration,slot=(length+32000)/32000)))
(p/'forget.json').write_text(json.dumps(dict(recording=dict(id=recording,title='t',kind='ad-hoc',startedAt=0,duration=0,state='sealed',revision=0,transcriptVersion=0,notes='',noteEntries=[],speakers=[],segments=[],transcriptState='unavailable',audioChunks=[],consentAnnounced=False,isDemo=False),personID=sys.argv[2])))
PY
"$helper" transcribe "$fixture" "$fixture/request.json" "$fixture/result.json" > "$fixture/pipeline.log" 2>&1

# Which detected voice is Thomas on each track, from the known timing.
python3 - "$fixture" "$person" <<'PY'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1]); meta=json.loads((p/'meta.json').read_text()); result=json.loads((p/'result.json').read_text())
slot=meta['slot']
def thomas(source):
    starts=[0,2] if source=='mic' else [1,3]
    scores={}
    for s in result['segments']:
        if s['source']==source and s.get('speakerID'):
            overlap=sum(max(0,min((k+1)*slot,s['end'])-max(k*slot,s['start'])) for k in starts)
            scores[s['speakerID']]=scores.get(s['speakerID'],0)+overlap
    return max(scores,key=scores.get)
recording=dict(id=meta['recording'],title='Voix synthétiques',kind='ad-hoc',startedAt=0,duration=meta['duration'],state='sealed',revision=0,transcriptVersion=1,
               notes='',noteEntries=[],speakers=result['speakers'],segments=result['segments'],transcriptState='ready',audioChunks=meta['chunks'],consentAnnounced=False,isDemo=False)
for source,name in (('mic','enroll-mic.json'),('system','enroll-system.json')):
    (p/name).write_text(json.dumps(dict(recording=recording,speakerID=thomas(source),personID=sys.argv[2])))
# The same person cannot be proposed for two voices of one session, so recognition on the call
# track runs on a copy that keeps only that track.
call=dict(recording, speakers=[s for s in result['speakers'] if s['source']=='system'], segments=[s for s in result['segments'] if s['source']=='system'])
(p/'identify-call.json').write_text(json.dumps(dict(recording=call)))
(p/'sources.json').write_text(json.dumps(dict(recording=recording,personID=sys.argv[2])))
(p/'withdraw.json').write_text(json.dumps(dict(recording=recording,personID=sys.argv[2],sourceRecordingID=meta['recording'])))
(p/'thomas.json').write_text(json.dumps(dict(mic=thomas('mic'),system=thomas('system'))))
PY
sqlite3 "$fixture/hwyd.sqlite" "INSERT INTO voice_people(id,payload) VALUES ('$person', CAST('{\"id\":\"$person\",\"name\":\"Synthetic Thomas\",\"enrollmentRequestedAt\":0,\"opposed\":false}' AS BLOB))"

"$helper" enroll-voice "$fixture" "$fixture/enroll-mic.json" "$fixture/matches-mic.json" >> "$fixture/pipeline.log" 2>&1
"$helper" voice-sources "$fixture" "$fixture/sources.json" "$fixture/sources-1.json" >> "$fixture/pipeline.log" 2>&1
"$helper" identify-voices "$fixture" "$fixture/identify-call.json" "$fixture/call-cross.json" >> "$fixture/pipeline.log" 2>&1
"$helper" enroll-voice "$fixture" "$fixture/enroll-system.json" "$fixture/matches-system.json" >> "$fixture/pipeline.log" 2>&1
"$helper" identify-voices "$fixture" "$fixture/identify-call.json" "$fixture/call-own.json" >> "$fixture/pipeline.log" 2>&1
"$helper" voice-sources "$fixture" "$fixture/sources.json" "$fixture/sources-2.json" >> "$fixture/pipeline.log" 2>&1
"$helper" forget-voice-source "$fixture" "$fixture/withdraw.json" "$fixture/out.json" >> "$fixture/pipeline.log" 2>&1
"$helper" voice-sources "$fixture" "$fixture/sources.json" "$fixture/sources-3.json" >> "$fixture/pipeline.log" 2>&1

python3 - "$fixture" "$person" <<'PY'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1]); person=sys.argv[2]; meta=json.loads((p/'meta.json').read_text()); thomas=json.loads((p/'thomas.json').read_text())
after_mic=json.loads((p/'matches-mic.json').read_text())
# One person, one voice per session: the microphone voice it was learned from wins.
assert list(after_mic)==[thomas['mic']] and after_mic[thomas['mic']]['personID']==person and after_mic[thomas['mic']]['crossChannel'] is False, after_mic
# Known only on the microphone, Thomas is still proposed on the call track, through the stricter fallback.
cross=json.loads((p/'call-cross.json').read_text())
print('cross-channel', cross)
assert list(cross)==[thomas['system']] and cross[thomas['system']]['crossChannel'] is True and cross[thomas['system']]['channel']=='mic' and cross[thomas['system']]['score']>=0.85, cross
own=json.loads((p/'call-own.json').read_text())
assert own[thomas['system']]['crossChannel'] is False and own[thomas['system']]['channel']=='remote', own
one=json.loads((p/'sources-1.json').read_text())
assert len(one)==1 and one[0]['channel']=='mic' and one[0]['count']==1 and one[0]['recordingID'].lower()==meta['recording'], one
two=json.loads((p/'sources-2.json').read_text())
assert sorted(c['channel'] for c in two)==['mic','remote'] and all(c['recordingID'].lower()==meta['recording'] for c in two), two
assert json.loads((p/'sources-3.json').read_text())==[]
for name in ('matches-mic.json','matches-system.json','call-cross.json','call-own.json','sources-1.json','sources-2.json'):
    text=(p/name).read_text().lower()
    assert 'vector' not in text and 'embedding' not in text
print('Voice memory: per-channel enrollment, cross-channel proposal, traceable samples, session withdrawal, no exported vectors: PASS')
PY
