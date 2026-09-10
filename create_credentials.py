from cryptography.fernet import Fernet
from getpass import getpass
import json

username = input("Enter SFX username: ")
password = getpass("Enter SFX password: ")

# Generate encryption key
key = Fernet.generate_key()

# Encrypt credentials
data = {
    "username": username,
    "password": password
}

cipher = Fernet(key)
encrypted_data = cipher.encrypt(json.dumps(data).encode())

# Save encrypted credentials
with open("credentials.enc", "wb") as file:
    file.write(key + b"\n" + encrypted_data)

print("Encrypted credentials saved to credentials.enc")
