"""Load the Home Office register of licensed worker sponsors into HerTech's Supabase.

Usage: HERTECH_BOT_TOKEN=... python3 load_sponsors.py register.csv 2026-11-26
The token is the events/data bot token; it can only write the sponsors and events tables.
"""
import csv, json, re, sys, os, urllib.request

SUPABASE = 'https://lpnfipdrxmdolqlsvkos.supabase.co'
KEY = 'sb_publishable_RxNzexmbNrm9pexDCfrxFw_7fntmbcs'
KEEP_ROUTES = ('Skilled Worker', 'Scale-up', 'Global Business Mobility: Graduate Trainee', 'Global Business Mobility: Senior or Specialist Worker')
TECH_WORDS = re.compile(r"\b(tech|techs|technology|technologies|technological|software|digital|data|analytics|ai|a\.i\.|artificial intelligence|machine learning|robotics?|cyber|cloud|computing|computer|computers|systems|labs?|semiconductors?|silicon|fintech|insurtech|healthtech|edtech|biotech|games|gaming|interactive|apps?|it services|it solutions|information technology|internet|online|web|devices|electronics|quantum|blockchain|saas|platforms?|networks?|telecom\w*|automation|engineering software)\b", re.I)
TECH_NAMES = re.compile(r"\b(google|alphabet|amazon|aws|microsoft|meta platforms|facebook|apple|deepmind|arm limited|ocado|revolut|monzo|starling|wise payments|deliveroo|skyscanner|bloomberg|palantir|ibm|oracle|salesforce|sage|darktrace|graphcore|spotify|netflix|uber|airbnb|stripe|cisco|intel|nvidia|qualcomm|samsung|sony|bytedance|tiktok|tencent|huawei|accenture|thoughtworks|capgemini|deloitte digital|atlassian|shopify|snowflake|databricks|cloudflare|gitlab|github|canva|figma|adobe|autodesk|dyson|jaguar land rover|rolls-royce|bae systems|babylon|benevolentai|wayve|improbable|cleo|gocardless|checkout\.com|zopa|octopus energy|kraken technologies|bt group|vodafone|sky uk|bbc|king\.com|rockstar|ubisoft|electronic arts|playstation)\b", re.I)

def main(path, updated_on):
    token = os.environ['HERTECH_BOT_TOKEN']
    orgs = {}
    with open(path, newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        col = {k.lower().strip(): k for k in reader.fieldnames}
        name_k = col.get('organisation name'); city_k = col.get('town/city'); county_k = col.get('county')
        rating_k = col.get('type & rating'); route_k = col.get('route')
        assert name_k and route_k, reader.fieldnames
        for row in reader:
            route = (row.get(route_k) or '').strip()
            if route not in KEEP_ROUTES: continue
            name = re.sub(r'\s+', ' ', (row.get(name_k) or '').strip())
            if not name: continue
            city = (row.get(city_k) or '').strip().title() if city_k else ''
            key = (name.lower(), city.lower())
            o = orgs.setdefault(key, {'name': name, 'city': city, 'county': (row.get(county_k) or '').strip().title() if county_k else '',
                                      'routes': [], 'rating': (row.get(rating_k) or '').strip() if rating_k else '',
                                      'is_tech': bool(TECH_WORDS.search(name) or TECH_NAMES.search(name)), 'updated_on': updated_on})
            if route not in o['routes']: o['routes'].append(route)
    rows = sorted(orgs.values(), key=lambda o: o['name'].lower())
    print(f'{len(rows)} sponsors, {sum(o["is_tech"] for o in rows)} tagged tech')
    total = 0
    for i in range(0, len(rows), 4000):
        body = json.dumps({'token': token, 'rows': rows[i:i + 4000], 'start_fresh': i == 0}).encode()
        req = urllib.request.Request(SUPABASE + '/rest/v1/rpc/bot_sponsors_load', data=body, method='POST',
                                     headers={'apikey': KEY, 'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=120) as res:
            total += int(res.read())
    print(f'loaded {total}')

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
