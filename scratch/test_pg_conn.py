import psycopg2

# Try connecting via direct connection or pooler
# Project reference: gmmxgjtlvilowwcudypm

hosts = [
    "db.gmmxgjtlvilowwcudypm.supabase.co",
    "aws-0-sa-east-1.pooler.supabase.com"
]

for h in hosts:
    try:
        print(f"Trying to connect to {h}...")
        conn = psycopg2.connect(
            dbname="postgres",
            user="postgres.gmmxgjtlvilowwcudypm" if "pooler" in h else "postgres",
            password="admin",
            host=h,
            port=6543 if "pooler" in h else 5432,
            connect_timeout=3
        )
        print("Connected successfully!")
        conn.close()
    except Exception as e:
        print(f"Connection failed: {e}")
