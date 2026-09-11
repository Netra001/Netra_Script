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

# IMPORTANT:
# Replace this with the actual SFX upload URL once known.
SFX_UPLOAD_URL = "https://sfx2.gs.com/"

# Folder containing files to upload
UPLOAD_FOLDER = r"F:\DEVOPs\Python\Files"

# Encrypted credential file
CREDENTIAL_FILE = "credentials.enc"

# Browser
HEADLESS = False

# Keep browser open after completion
KEEP_BROWSER_OPEN = True

# Supported file types
ALLOWED_EXTENSIONS = {
    ".txt",
    ".csv",
    ".zip",
    ".pgp",
    ".gpg"
}


# ============================================================
# LOAD ENCRYPTED CREDENTIALS
# ============================================================

def load_credentials():

    if not os.path.exists(CREDENTIAL_FILE):

        print()
        print("ERROR: credentials.enc not found.")
        print()
        print("Run:")
        print("python create_credentials.py")

        sys.exit(1)

    try:

        with open(CREDENTIAL_FILE, "rb") as file:

            key = file.readline().strip()
            encrypted_data = file.read()

        cipher = Fernet(key)

        decrypted_data = cipher.decrypt(
            encrypted_data
        )

        credentials = json.loads(
            decrypted_data.decode()
        )

        username = credentials["username"]
        password = credentials["password"]

        return username, password

    except Exception as e:

        print()
        print("ERROR: Could not decrypt credentials.")
        print(e)

        sys.exit(1)


# ============================================================
# FIND FILES
# ============================================================

def get_files():

    print()
    print("Checking upload folder:")
    print(UPLOAD_FOLDER)

    if not os.path.isdir(UPLOAD_FOLDER):

        print()
        print("ERROR: Upload folder does not exist.")
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

        extension = os.path.splitext(
            filename
        )[1].lower()

        if extension in ALLOWED_EXTENSIONS:

            files.append(full_path)

    if not files:

        print()
        print("ERROR: No supported files found.")

        sys.exit(1)

    print()
    print(f"Files found: {len(files)}")

    for file in files:

        print(
            "  " + os.path.basename(file)
        )

    return files


# ============================================================
# DEBUG PAGE
# ============================================================

def save_debug(page):

    print()
    print("Creating debug information...")

    try:

        page.screenshot(
            path="sfx_debug.png",
            full_page=True
        )

        print(
            "Screenshot saved: sfx_debug.png"
        )

    except Exception as e:

        print(
            "Screenshot error:",
            e
        )

    try:

        with open(
            "sfx_debug.html",
            "w",
            encoding="utf-8"
        ) as file:

            file.write(
                page.content()
            )

        print(
            "HTML saved: sfx_debug.html"
        )

    except Exception as e:

        print(
            "HTML error:",
            e
        )


# ============================================================
# SHOW LOGIN ELEMENTS
# ============================================================

def inspect_login_page(page):

    print()
    print("=" * 60)
    print("SFX LOGIN PAGE INSPECTION")
    print("=" * 60)

    # --------------------------------------------------------
    # Buttons
    # --------------------------------------------------------

    buttons = page.locator("button")

    print()
    print(
        f"BUTTONS FOUND: {buttons.count()}"
    )

    for i in range(buttons.count()):

        try:

            button = buttons.nth(i)

            print()
            print(f"Button {i}")

            print(
                "  Text  :",
                repr(button.inner_text())
            )

            print(
                "  ID    :",
                button.get_attribute("id")
            )

            print(
                "  Name  :",
                button.get_attribute("name")
            )

            print(
                "  Type  :",
                button.get_attribute("type")
            )

            print(
                "  Class :",
                button.get_attribute("class")
            )

        except Exception:
            pass

    # --------------------------------------------------------
    # Inputs
    # --------------------------------------------------------

    inputs = page.locator("input")

    print()
    print(
        f"INPUTS FOUND: {inputs.count()}"
    )

    for i in range(inputs.count()):

        try:

            element = inputs.nth(i)

            print()
            print(f"Input {i}")

            print(
                "  Type  :",
                element.get_attribute("type")
            )

            print(
                "  ID    :",
                element.get_attribute("id")
            )

            print(
                "  Name  :",
                element.get_attribute("name")
            )

            print(
                "  Class :",
                element.get_attribute("class")
            )

        except Exception:
            pass

    # --------------------------------------------------------
    # Links
    # --------------------------------------------------------

    links = page.locator("a")

    print()
    print(
        f"LINKS FOUND: {links.count()}"
    )

    for i in range(links.count()):

        try:

            link = links.nth(i)

            text = link.inner_text().strip()

            if text:

                print(
                    f"Link {i}: {text}"
                )

        except Exception:
            pass


# ============================================================
# LOGIN
# ============================================================

def login(page, username, password):

    print()
    print("=" * 60)
    print("LOGIN")
    print("=" * 60)

    print()
    print("Opening SFX login page...")

    page.goto(
        SFX_LOGIN_URL,
        wait_until="commit",
        timeout=60000
    )

    print("SFX login page opened. Waiting for login form...")

    page.locator('input[type="password"]').first.wait_for(
        state="visible",
        timeout=90000
    )

    # --------------------------------------------------------
    # USERNAME
    # --------------------------------------------------------

    username_selectors = [
        'input[name="username"]',
        'input[name="userName"]',
        'input[id="username"]',
        'input[id="userName"]',
        'input[type="email"]',
        'input[type="text"]'
    ]

    username_field = None

    for selector in username_selectors:

        try:

            locator = page.locator(selector)

            if locator.count() > 0:

                for i in range(locator.count()):

                    element = locator.nth(i)

                    if element.is_visible():

                        username_field = element

                        print(
                            "Username field:",
                            selector
                        )

                        break

            if username_field:
                break

        except Exception:
            pass

    if username_field is None:

        print()
        print("ERROR: Username field not found.")

        inspect_login_page(page)
        save_debug(page)

        raise Exception(
            "Username field not found."
        )

    username_field.fill(username)

    print("Username entered.")

    # --------------------------------------------------------
    # PASSWORD
    # --------------------------------------------------------

    password_selectors = [
        'input[name="password"]',
        'input[name="Password"]',
        'input[id="password"]',
        'input[id="Password"]',
        'input[type="password"]'
    ]

    password_field = None

    for selector in password_selectors:

        try:

            locator = page.locator(selector)

            if locator.count() > 0:

                for i in range(locator.count()):

                    element = locator.nth(i)

                    if element.is_visible():

                        password_field = element

                        print(
                            "Password field:",
                            selector
                        )

                        break

            if password_field:
                break

        except Exception:
            pass

    if password_field is None:

        print()
        print("ERROR: Password field not found.")

        inspect_login_page(page)
        save_debug(page)

        raise Exception(
            "Password field not found."
        )

    password_field.fill(password)

    print("Password entered.")

    # --------------------------------------------------------
    # FIND LOGIN BUTTON
    # --------------------------------------------------------

    print()
    print("Looking for Login button...")

    login_button = None

    # --------------------------------------------------------
    # Method 1: Button containing Login
    # --------------------------------------------------------

    try:

        buttons = page.locator("button")

        for i in range(buttons.count()):

            button = buttons.nth(i)

            if not button.is_visible():
                continue

            text = button.inner_text().strip().lower()

            if (
                "login" in text
                or
                "log in" in text
                or
                "sign in" in text
                or
                "signin" in text
            ):

                login_button = button

                print(
                    "Login button found using button text."
                )

                break

    except Exception:
        pass

    # --------------------------------------------------------
    # Method 2: Input button
    # --------------------------------------------------------

    if login_button is None:

        try:

            inputs = page.locator("input")

            for i in range(inputs.count()):

                element = inputs.nth(i)

                if not element.is_visible():
                    continue

                element_type = (
                    element.get_attribute("type")
                    or ""
                ).lower()

                value = (
                    element.get_attribute("value")
                    or ""
                ).lower()

                if (
                    element_type in
                    ["submit", "button"]
                ):

                    if (
                        "login" in value
                        or
                        "log in" in value
                        or
                        "sign in" in value
                        or
                        "signin" in value
                        or
                        value == ""
                    ):

                        login_button = element

                        print(
                            "Login button found using input."
                        )

                        break

        except Exception:
            pass

    # --------------------------------------------------------
    # Method 3: Role
    # --------------------------------------------------------

    if login_button is None:

        for name in [
            "Login",
            "Log In",
            "Sign In",
            "Sign in"
        ]:

            try:

                locator = page.get_by_role(
                    "button",
                    name=name,
                    exact=True
                )

                if locator.count() > 0:

                    login_button = locator.first

                    print(
                        f"Login button found using role: {name}"
                    )

                    break

            except Exception:
                pass

    # --------------------------------------------------------
    # LOGIN BUTTON NOT FOUND
    # --------------------------------------------------------

    if login_button is None:

        print()
        print("=" * 60)
        print("LOGIN BUTTON NOT FOUND")
        print("=" * 60)

        print()
        print(
            "Playwright cannot identify the SFX login button."
        )

        inspect_login_page(page)
        save_debug(page)

        print()
        print(
            "Debug files created:"
        )

        print(
            "  sfx_debug.png"
        )

        print(
            "  sfx_debug.html"
        )

        raise Exception(
            "SFX Login button selector needs to be identified."
        )

    # --------------------------------------------------------
    # CLICK
    # --------------------------------------------------------

    print()
    print("Clicking Login button...")

    login_button.click(
        timeout=10000
    )

    print("Login button clicked.")

    # --------------------------------------------------------
    # Wait
    # --------------------------------------------------------

    time.sleep(5)

    print()
    print("Current URL:")
    print(page.url)

    print()
    print("Login step completed.")


# ============================================================
# NAVIGATE TO UPLOAD PAGE
# ============================================================

def navigate_to_upload(page):

    print()
    print("=" * 60)
    print("NAVIGATION")
    print("=" * 60)

    print()
    print(
        "Opening upload page..."
    )

    page.goto(
        SFX_UPLOAD_URL,
        wait_until="commit",
        timeout=60000
    )

    page.locator('input[type="file"]').first.wait_for(
        state="attached",
        timeout=90000
    )

    print(
        "Current URL:",
        page.url
    )


# ============================================================
# FIND FILE INPUT
# ============================================================

def find_file_input(page):

    file_inputs = page.locator(
        'input[type="file"]'
    )

    if file_inputs.count() == 0:

        print()
        print(
            "ERROR: File input not found."
        )

        save_debug(page)

        raise Exception(
            "SFX file upload input not found."
        )

    for i in range(file_inputs.count()):

        try:

            element = file_inputs.nth(i)

            print(
                f"File input found: {i}"
            )

            return element

        except Exception:
            pass

    raise Exception(
        "Unable to use file input."
    )


# ============================================================
# UPLOAD FILES
# ============================================================

def upload_files(page, files):

    print()
    print("=" * 60)
    print("FILE UPLOAD")
    print("=" * 60)

    file_input = find_file_input(page)

    print()
    print(
        f"Selecting {len(files)} file(s)..."
    )

    # --------------------------------------------------------
    # Upload files
    # --------------------------------------------------------

    file_input.set_input_files(files)

    print()
    print("Files selected successfully.")

    for file in files:

        print(
            "  " + os.path.basename(file)
        )

    # --------------------------------------------------------
    # Find Upload button
    # --------------------------------------------------------

    print()
    print("Looking for Upload button...")

    upload_button = None

    buttons = page.locator("button")

    for i in range(buttons.count()):

        try:

            button = buttons.nth(i)

            if not button.is_visible():
                continue

            text = button.inner_text().strip().lower()

            if "upload" in text:

                upload_button = button

                print(
                    "Upload button found."
                )

                break

        except Exception:
            pass

    # --------------------------------------------------------
    # Input button
    # --------------------------------------------------------

    if upload_button is None:

        inputs = page.locator("input")

        for i in range(inputs.count()):

            try:

                element = inputs.nth(i)

                if not element.is_visible():
                    continue

                value = (
                    element.get_attribute("value")
                    or ""
                ).lower()

                if "upload" in value:

                    upload_button = element

                    print(
                        "Upload button found."
                    )

                    break

            except Exception:
                pass

    # --------------------------------------------------------
    # Not found
    # --------------------------------------------------------

    if upload_button is None:

        print()
        print(
            "ERROR: Upload button not found."
        )

        save_debug(page)

        raise Exception(
            "SFX Upload button needs to be identified."
        )

    # --------------------------------------------------------
    # Click upload
    # --------------------------------------------------------

    print()
    print("Clicking Upload...")

    upload_button.click(
        timeout=30000
    )

    print(
        "Upload button clicked."
    )

    time.sleep(5)


# ============================================================
# VERIFY UPLOAD
# ============================================================

def verify_upload(page, files):

    print()
    print("=" * 60)
    print("UPLOAD VERIFICATION")
    print("=" * 60)

    time.sleep(5)

    # --------------------------------------------------------
    # Check common success messages
    # --------------------------------------------------------

    success_messages = [
        "Upload successful",
        "Successfully uploaded",
        "Upload completed",
        "File uploaded",
        "Files uploaded",
        "Upload Success",
        "Success"
    ]

    for message in success_messages:

        try:

            locator = page.get_by_text(
                message,
                exact=False
            )

            if locator.count() > 0:

                print()
                print(
                    "SUCCESS MESSAGE FOUND:"
                )

                print(message)

                return True

        except Exception:
            pass

    # --------------------------------------------------------
    # Check filenames on page
    # --------------------------------------------------------

    print()
    print(
        "Checking filenames..."
    )

    verified = 0

    for file in files:

        filename = os.path.basename(file)

        try:

            locator = page.get_by_text(
                filename,
                exact=False
            )

            if locator.count() > 0:

                print(
                    f"Verified: {filename}"
                )

                verified += 1

            else:

                print(
                    f"Not verified: {filename}"
                )

        except Exception:

            print(
                f"Could not verify: {filename}"
            )

    if verified == len(files):

        print()
        print(
            "ALL FILES VERIFIED."
        )

        return True

    print()
    print(
        "WARNING: Upload was performed, "
        "but success could not be automatically verified."
    )

    save_debug(page)

    return False


# ============================================================
# MAIN
# ============================================================

def main():

    print()
    print("=" * 60)
    print("SFX FILE UPLOAD AUTOMATION")
    print("=" * 60)

    # --------------------------------------------------------
    # Credentials
    # --------------------------------------------------------

    username, password = load_credentials()

    print()
    print(
        "Encrypted credentials loaded."
    )

    # --------------------------------------------------------
    # Files
    # --------------------------------------------------------

    files = get_files()

    # --------------------------------------------------------
    # Playwright
    # --------------------------------------------------------

    with sync_playwright() as p:

        browser = None

        try:

            print()
            print(
                "Launching Chromium..."
            )

            browser = p.chromium.launch(
                headless=HEADLESS
            )

            context = browser.new_context()

            page = context.new_page()

            # ------------------------------------------------
            # LOGIN
            # ------------------------------------------------

            login(
                page,
                username,
                password
            )

            # ------------------------------------------------
            # NAVIGATION
            # ------------------------------------------------

            navigate_to_upload(
                page
            )

            # ------------------------------------------------
            # UPLOAD
            # ------------------------------------------------

            upload_files(
                page,
                files
            )

            # ------------------------------------------------
            # VERIFY
            # ------------------------------------------------

            result = verify_upload(
                page,
                files
            )

            print()
            print("=" * 60)

            if result:

                print(
                    "FINAL RESULT: SUCCESS"
                )

            else:

                print(
                    "FINAL RESULT: "
                    "UPLOAD DONE - VERIFICATION FAILED"
                )

            print("=" * 60)

            # ------------------------------------------------
            # Keep browser open
            # ------------------------------------------------

            if KEEP_BROWSER_OPEN:

                input(
                    "\nPress Enter to close browser..."
                )

        except PlaywrightTimeoutError as e:

            print()
            print("=" * 60)
            print("PLAYWRIGHT TIMEOUT ERROR")
            print("=" * 60)

            print(e)

            try:
                save_debug(page)
            except Exception:
                pass

            input(
                "\nPress Enter to close browser..."
            )

        except Exception as e:

            print()
            print("=" * 60)
            print("ERROR")
            print("=" * 60)

            print(e)

            try:
                save_debug(page)
            except Exception:
                pass

            input(
                "\nPress Enter to close browser..."
            )

        finally:

            if browser:

                browser.close()


# ============================================================
# START
# ============================================================

if __name__ == "__main__":
    main()

