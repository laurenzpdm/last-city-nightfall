import json,sys
for line in open(sys.argv[1]):
    if line.startswith('REFUSALS'): print(line.strip()); continue
    if not line.startswith('=== '): continue
    d=json.loads(line[4:])
    h=d['heat']
    print("T%-5d supply %6.2f demand %6.2f deficit %5.2f nets %d frozen %d brownouts %d | turrets %s burners_short %s line_dry %s stalled %d" % (
        d['t'], h['supply'], h['demand'], h['deficit'], h['networks'], h['frozen'], h['brownouts'],
        d.get('turrets'), d.get('logi',{}).get('burners_short'), d.get('logi',{}).get('line_dry'), len(d.get('stalled',[]))))
    for n in d['nets']:
        print("        net %d: supply %.2f demand %.2f deficit %.2f starved %s brownouts %s consumers %s nodes %s" % (
            n['id'],n['supply'],n['demand'],n['deficit'],n['starved'],n['brownouts'],n['consumers'],n['nodes']))
    for b in d['b']:
        flag = 'FROZEN' if b['frozen'] else ''
        print("        %-18s %-11s net %-3s pf %.2f fuel %6.1f st %d w %s %s %s" % (b['kind'],b['cell'],b['net'],b['pf'],b['fuel'],b['state'],b['workers'],flag,b['bn'] or ''))
    for s in d.get('stalled',[]): print("        STALL", json.dumps(s)[:220])
    print("        cit", d.get('cit'))
