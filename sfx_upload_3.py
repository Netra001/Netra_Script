from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeoutError

from cryptography.fernet import Fernet

import json
import os
import sys
import time


# ============================================================
# CONFIGURATION
# ============================================================

SFX_LOGIN_URL = "https://sfx2.gs.com/login/"

# Change this to the actual SFX upload page if required.
SFX_UPLOAD_URL = "https://sfx2.gs.com/?path=./incoming1"

# Folder containing files to upload
UPLOAD_FOLDER = r"F:\DEVOPs\Python\Files"

# File extensions allowed for upload
ALLOWED_EXTENSIONS = {
    ".txt",
    ".csv",
    ".zip",
    ".pgp",
    ".gpg"
}

# Credential file
CREDENTIAL_FILE = "credentials.enc"

# Keep browser open after upload
KEEP_BROWSER_OPEN = True


# ============================================================
# LOAD ENCRYPTED CREDENTIALS
# ============================================================

def load_credentials():
    if not os.path.exists(CREDENTIAL_FILE):
        print(f"ERROR: Credential file not found: {CREDENTIAL_FILE}")
        sys.exit(1)
    try:
        with open(CREDENTIAL_FILE, "rb") as file:
            key = file.readline().strip()
            encrypted_data = file.read()
        cipher = Fernet(key)
        decrypted_data = cipher.decrypt(encrypted_data)
        credentials = json.loads(decrypted_data.decode())
        return credentials["username"], credentials["password"]
    except Exception as e:
        print(f"ERROR: Unable to decrypt credentials: {e}")
        sys.exit(1)


# ============================================================
# GET FILES
# ============================================================

def get_files():
    if not os.path.exists(UPLOAD_FOLDER):
        print(f"ERROR: Upload folder does not exist:")
        print(UPLOAD_FOLDER)
        sys.exit(1)
    files = []
    for filename in os.listdir(UPLOAD_FOLDER):
        full_path = os.path.join(
            UPLOAD_FOLDER,
            filename
        )
        if not os.path.isfile(full_path):
            continue
        extension = os.path.splitext(filename)[1].lower()
        if extension in ALLOWED_EXTENSIONS:
            files.append(full_path)
    if not files:
        print("ERROR: No files found for upload.")
        sys.exit(1)
    return files


# ============================================================
# FIND LOGIN BUTTON (more resilient + self-diagnosing)
# ============================================================

def find_login_button(page):
    """
    Try a wider range of common login-button patterns.
    If none match, dump every clickable-looking element on the
    page so the real selector can be identified instead of just
    timing out with no information.
    """

    candidates = [
        lambda: page.get_by_role("button", name="Login", exact=True),
        lambda: page.get_by_role("button", name="Log In", exact=True),
        lambda: page.get_by_role("button", name="Log in", exact=True),
        lambda: page.get_by_role("button", name="Sign in", exact=True),
        lambda: page.get_by_role("button", name="Sign In", exact=True),
        lambda: page.get_by_role("button", name="Submit", exact=True),
        lambda: page.locator('button:has-text("Login")'),
        lambda: page.locator('button:has-text("Log In")'),
        lambda: page.locator('button:has-text("Log in")'),
        lambda: page.locator('button:has-text("Sign in")'),
        lambda: page.locator('a:has-text("Login")'),
        lambda: page.locator('a:has-text("Sign in")'),
        lambda: page.locator('input[type="submit"], button[type="submit"]'),
        lambda: page.locator('input[type="submit"][value*="Login" i]'),
        lambda: page.locator('input[type="submit"][value*="Sign" i]'),
        lambda: page.locator('[id*="login" i][type="submit"], [id*="login" i][role="button"]'),
        lambda: page.locator('[class*="login" i] button, [class*="signin" i] button'),
    ]

    for candidate in candidates:
        try:
            locator = candidate().first
            if locator.count() > 0:
                return locator
        except Exception:
            continue

    # --------------------------------------------------------
    # Nothing matched - dump diagnostics before failing so the
    # correct selector can be identified from the output.
    # --------------------------------------------------------
    print()
    print("DIAGNOSTIC: No known login-button pattern matched.")
    print("Listing buttons / submit inputs / links found on the page:")
    print()

    try:
        buttons = page.locator("button").all_inner_texts()
        print(f"  <button> elements ({len(buttons)}):")
        for text in buttons:
            print(f"    - {text!r}")
    except Exception as e:
        print(f"  Could not list <button> elements: {e}")

    try:
        submits = page.locator('input[type="submit"]')
        count = submits.count()
        print(f"  <input type=submit> elements ({count}):")
        for i in range(count):
            value = submits.nth(i).get_attribute("value")
            print(f"    - value={value!r}")
    except Exception as e:
        print(f"  Could not list <input type=submit> elements: {e}")

    try:
        links = page.locator("a").all_inner_texts()
        interesting_links = [t for t in links if t.strip()]
        print(f"  <a> elements with text ({len(interesting_links)}):")
        for text in interesting_links[:30]:
            print(f"    - {text!r}")
    except Exception as e:
        print(f"  Could not list <a> elements: {e}")

    raise Exception(
        "Could not locate a login button on the page. "
        "See diagnostic output above and update find_login_button() "
        "with the correct selector."
    )


# ============================================================
# LOGIN
# ============================================================

def login(page, username, password):
    print("Opening SFX login page...")
    page.goto(
        SFX_LOGIN_URL,
        wait_until="commit",
        timeout=30000
    )
    print("SFX login page opened.")

    # --------------------------------------------------------
    # IMPORTANT:
    # These selectors may need to be changed based on
    # the actual SFX login page.
    # --------------------------------------------------------
    username_field = page.locator(
        'input[type="text"], input[type="email"], input[name="username"]'
    ).first
    password_field = page.locator(
        'input[type="password"], input[name="password"]'
    ).first

    username_field.wait_for(
        state="visible",
        timeout=90000
    )
    username_field.fill(username)
    print("Username entered.")

    password_field.fill(password)
    print("Password entered.")

    # Find login button with wider fallback + diagnostics
    login_button = find_login_button(page)

    login_button.wait_for(
        state="visible",
        timeout=90000
    )
    login_button.click(timeout=90000)
    print("Login submitted.")

    # Wait for navigation
    page.wait_for_load_state(
        "domcontentloaded",
        timeout=90000
    )
    time.sleep(3)
    print("Current URL:")
    print(page.url)


# ============================================================
# NAVIGATE TO UPLOAD PAGE
# ============================================================

def navigate_to_upload(page):
    print("Navigating to SFX upload page...")
    # If the upload page has a direct URL, use it.
    #
    # Otherwise, comment this line and use the menu
    # navigation below.
    page.goto(
        SFX_UPLOAD_URL,
        wait_until="commit",
        timeout=30000
    )
    page.locator('input[type="file"]').first.wait_for(
        state="attached",
        timeout=90000
    )
    print("Upload page opened.")


# ============================================================
# UPLOAD FILES
# ============================================================

def upload_files(page, files):
    print()
    print("Files selected for upload:")
    for file in files:
        print("  " + file)

    # --------------------------------------------------------
    # Find file input
    # --------------------------------------------------------
    file_input = page.locator(
        'input[type="file"]'
    ).first
    file_input.wait_for(
        state="attached",
        timeout=90000
    )

    print()
    print("Uploading files...")

    # Upload all files
    file_input.set_input_files(files)
    print("Files attached successfully.")

    # --------------------------------------------------------
    # Click Upload button
    # --------------------------------------------------------
    upload_button = page.get_by_role(
        "button",
        name="Upload",
        exact=True
    )
    if upload_button.count() == 0:
        upload_button = page.locator(
            'input[type="submit"][value*="Upload"], '
            'button:has-text("Upload")'
        ).first

    upload_button.wait_for(
        state="visible",
        timeout=90000
    )
    upload_button.click()
    print("Upload button clicked.")


# ============================================================
# VERIFY UPLOAD
# ============================================================

def verify_upload(page, files):
    print()
    print("Waiting for upload to complete...")
    time.sleep(5)

    # --------------------------------------------------------
    # Look for common success messages
    # --------------------------------------------------------
    success_messages = [
        "Upload successful",
        "Successfully uploaded",
        "Upload completed",
        "File uploaded",
        "Files uploaded",
        "Success"
    ]

    success_found = False
    for message in success_messages:
        try:
            locator = page.get_by_text(
                message,
                exact=False
            )
            if locator.count() > 0:
                print()
                print("UPLOAD SUCCESS")
                print(f"Detected message: {message}")
                success_found = True
                break
        except Exception:
            pass

    # --------------------------------------------------------
    # If no success message is found, check whether
    # uploaded filenames are visible on the page.
    # --------------------------------------------------------
    if not success_found:
        visible_files = 0
        for file in files:
            filename = os.path.basename(file)
            try:
                if page.get_by_text(
                    filename,
                    exact=False
                ).count() > 0:
                    print(
                        f"Verified file: {filename}"
                    )
                    visible_files += 1
            except Exception:
                pass

        if visible_files == len(files):
            print()
            print("UPLOAD VERIFIED")
            return True

    if not success_found:
        print()
        print(
            "WARNING: Upload completed, but "
            "automatic verification could not be confirmed."
        )
        return False

    return True


# ============================================================
# MAIN
# ============================================================

def main():
    print("=" * 60)
    print("SFX FILE UPLOAD AUTOMATION")
    print("=" * 60)

    # Load credentials
    username, password = load_credentials()
    print("Encrypted credentials loaded.")

    # Get files
    files = get_files()
    print()
    print(f"Found {len(files)} file(s) to upload.")

    # Start Playwright
    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=False
        )
        context = browser.new_context()
        page = context.new_page()

        try:
            # Login
            login(
                page,
                username,
                password
            )

            # Navigate
            navigate_to_upload(page)

            # Upload
            upload_files(
                page,
                files
            )

            # Verify
            result = verify_upload(
                page,
                files
            )

            print()
            print("=" * 60)
            if result:
                print("FINAL RESULT: SUCCESS")
            else:
                print("FINAL RESULT: VERIFICATION FAILED")
            print("=" * 60)

            # Keep browser open
            if KEEP_BROWSER_OPEN:
                input(
                    "\nPress Enter to close the browser..."
                )

        except PlaywrightTimeoutError as e:
            print()
            print("PLAYWRIGHT TIMEOUT ERROR")
            print(e)
            input(
                "\nPress Enter to close the browser..."
            )
        except Exception as e:
            print()
            print("ERROR:")
            print(e)
            input(
                "\nPress Enter to close the browser..."
            )
        finally:
            browser.close()


# ============================================================
# START
# ============================================================

if __name__ == "__main__":
    main()
