import os
from dotenv import load_dotenv
from openai import OpenAI

load_dotenv()

PROVIDERS = {
    "muse":   {"base_url": os.getenv("MUSE_BASE_URL"), "key": os.getenv("MUSE_API_KEY"),   "model": os.getenv("MUSE_MODEL"),
               "label": "Meta Muse"},
    "openai": {"base_url": None,                       "key": os.getenv("OPENAI_API_KEY"), "model": "gpt-4o-mini",
               "label": "OpenAI"},
}
PRIMARY = os.getenv("LLM_PROVIDER", "muse")
# try the chosen provider first; if it fails (out of credits, down), fall back to the other one if it has a key
ORDER = [PRIMARY] + [p for p in PROVIDERS if p != PRIMARY and PROVIDERS[p]["key"]]
clients = {name: OpenAI(base_url=c["base_url"], api_key=c["key"] or "missing") for name, c in PROVIDERS.items()}


def ask(prompt, system=None, with_source=False):
    """Ask the AI. with_source=True also returns who answered, e.g. ("...", "Meta Muse")."""
    messages = [{"role": "system", "content": system}] if system else []
    messages.append({"role": "user", "content": prompt})
    error = None
    for name in ORDER:
        try:
            r = clients[name].chat.completions.create(model=PROVIDERS[name]["model"], messages=messages)
            text = r.choices[0].message.content
            return (text, PROVIDERS[name]["label"]) if with_source else text
        except Exception as e:
            error = e
            print(f"[llm] {name} failed: {e}")
    raise error