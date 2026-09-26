from openai import OpenAI
from llm import PROVIDERS

for name, cfg in PROVIDERS.items():
    if not cfg["key"]:
        print(f"{name:7} SKIPPED  (no key in .env)")
        continue
    try:
        client = OpenAI(base_url=cfg["base_url"], api_key=cfg["key"])
        r = client.chat.completions.create(
            model=cfg["model"],
            messages=[{"role": "user", "content": "Say hi in 5 words"}],
        )
        print(f"{name:7} OK       {r.choices[0].message.content.strip()}")
    except Exception as e:
        print(f"{name:7} FAILED   {type(e).__name__}: {str(e)[:120]}")