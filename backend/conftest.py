import os

# Tests never read the developer's backend/.env (it may hold real keys or MOCK=0).
os.environ["DOTENV"] = "0"
