---
authority: null
body_embedding_mode: "gemma"
body_tsv: "'-08':21A '-28':22A '01.828':25A '1':28A '17':24A '1787883956207':33A '1h':50A '2026':20A '3070':81A 'activ':55A 'advanc':48A 'claim':107A 'code':60A 'commit':56A,73A,86A,124A 'commitstal':11A 'common':88A 'dbos':91A 'deploy':65A,70A 'detail':36A 'edit':77A 'emit':31A 'engin':99A 'error':111A 'errorstal':15A 'executor':92A 'fals':14A,16A,18A 'fire':98A 'firestal':13A 'fix':105A 'git':3A,38A,84A,96A,118A 'git-sync':37A,83A,95A,117A 'git-sync-watchdog':2A 'har':6A 'head':45A,74A 'headunchangedhr':27A 'inspect':109A 'kind':1A 'land':59A 'lastfiredat':19A 'laststatus':29A 'lock/restart':102A 'matter':68A 'metadata.last':110A 'mobil':10A,116A 'persistentreap':17A 'reach':80A 'reap':93A 'rescu':123A 'rescue-commit':122A 'root':89A 'routin':53A,120A 'ship':71A 'sidestag':9A,115A 'sidestage-mobil':8A,114A 'silent':40A 'slug':7A 'stall':41A 'strand':34A,61A,76A,129A 'stuck':94A 'sync':4A,30A,39A,85A,97A,119A 't02':23A 'tree':44A,126A 'true':12A,35A 'un':64A 'un-deploy':63A 'uncommit':62A 'urgent':131A 'watchdog':5A,42A 'wedg':100A 'won':103A 'z':26A"
escalation: "{\"kind\":\"git-sync-watchdog\",\"harness_slug\":\"sidestage-mobile\",\"commitStale\":true,\"fireStale\":false,\"errorStall\":false,\"persistentReap\":false,\"lastFiredAt\":\"2026-08-28T02:17:01.828Z\",\"headUnchangedHrs\":1,\"lastStatus\":\"synced\",\"emitted_at\":1787883956207,\"stranding\":true,\"detail\":\"git-sync silent stall (watchdog): the tree HEAD has not advanced in ~1h while the routine is active — commits are NOT landing (code strands uncommitted + un-deployable). Why it matters: a deploy ships only COMMITTED HEAD, so stranded edits can't reach :3070 until git-sync commits them. Common root: a DBOS executor reaping stuck git-sync fires (engine wedge — a lock/restart won't fix it). Claim it: inspect metadata.last_error on the sidestage-mobile git-sync routine, and rescue-commit the tree if the strand is urgent.\"}"
mtime_ms: 1787883956207
phase: "git-sync-watchdog"
risk_tier: null
supervisor_notes: null
---


