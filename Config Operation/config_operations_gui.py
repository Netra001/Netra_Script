"""
======================================================================
Config Operations - Python GUI Front End
======================================================================
Replaces the PowerShell WinForms GUI.

 - GUI              : Python / Tkinter
 - AWS discovery    : aws CLI via subprocess (same queries as original)
 - Remote execution : ConfigOperations-Backend.ps1 (PowerShell backend)

The PowerShell backend keeps all the original remote logic
(Invoke-Command, scheduled tasks, IIS/WebAdministration, PID
verification, HTML report) because those must run in PowerShell.
======================================================================
"""

import json
import os
import queue
import shutil
import socket
import subprocess
import sys
import threading
import tkinter as tk
from datetime import datetime
from tkinter import filedialog, messagebox, scrolledtext, ttk

# ======================================================================
# CONFIGURATION
# ======================================================================

def resource_path(filename):
    """
    Locate a bundled resource.

    When running as a PyInstaller --onefile exe, bundled files are
    extracted to a temporary folder exposed as sys._MEIPASS. When
    running as a plain script, they sit next to this file.

    A copy sitting beside the exe takes priority, so the backend can be
    patched without rebuilding.
    """
    beside_exe = os.path.join(
        os.path.dirname(os.path.abspath(sys.executable)), filename
    )
    if getattr(sys, "frozen", False) and os.path.exists(beside_exe):
        return beside_exe

    base = getattr(
        sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__))
    )
    return os.path.join(base, filename)


BACKEND_SCRIPT = resource_path("ConfigOperations-Backend.ps1")

COPY_FILE_DIRECTORY = r"C:\CopyFiles"

LOG_FOLDER = r"C:\Temp"

AVAILABILITY_ZONES_DEFAULT_SERVER_TYPE = "tnp"

# ======================================================================
# STATIC LISTS (ported verbatim from the PowerShell script)
# ======================================================================

STACK_LIST = ["Blue", "Green", "None"]

OPERATIONS_LIST = [
    "Process Management",
    "Task Management",
    "IIS Management",
    "File Management",
]

PROCESSES_LIST = [
    "DbbAppServer*", "Rundbb*", "DbbAppServer_CoreAuth*",
    "DbbAppServer_CoreIssue*", "DbbAppServer_Services*",
    "Rundbb_AccountParametersUpdates*", "Rundbb_AccountReinstate*",
    "Rundbb_ACHBHubCreatePIIRequest*", "Rundbb_ACHBHubSendPIIRequest*",
    "Rundbb_ACHCreatePIIRequest*", "Rundbb_ACHSendPIIRequest*",
    "Rundbb_AlertNotification*", "Rundbb_BatchNotification",
    "Rundbb_BatchNotification2", "Rundbb_CBRBHubCreatePIIRequest*",
    "Rundbb_CBRBHubSendPIIRequest*", "Rundbb_CBRCreatePIIRequest*",
    "Rundbb_CBRSendPIIRequest*", "Rundbb_CoreAuthAging*",
    "Rundbb_CoreAuthManualAdminMessage*", "Rundbb_CoreAuthRetryAlert*",
    "Rundbb_CoreIssueRetryAlert*", "Rundbb_DBPD*", "Rundbb_ETNP*",
    "Rundbb_MCSink*", "Rundbb_MCSource*", "Rundbb_MergeAccounts*",
    "Rundbb_MSMQ*", "Rundbb_RetailAuthJobs*", "Rundbb_RewardAutoRedeem*",
    "Rundbb_Rewardnotification*", "Rundbb_TNP*", "Rundbb_UpdateCall*",
    "Rundbb_APJob*", "Rundbb_PendingTxn*", "Rundbb_RewardPromoDetails*",
    "Rundbb_APIQueue*", "Rundbb_CBRManualDF*",
    "Rundbb_BulkCardFileValidator*", "Rundbb_IPMSettlement*",
    "Rundbb_BulkSOLDAPICall*", "keyedhashpopulator*",
    "Rundbb_BillPayPayment*", "Rundbb_LockBox*", "Rundbb_AccountCreation*",
    "Rundbb_ThirdPartyAlerts*",
]

TASKS_LIST = [
    "Task_*", "Task_DbbAppServer_CoreAuth*", "Task_DbbAppServer_CoreIssue*",
    "Task_DbbAppServer_Services*", "Task_AccountParametersUpdates*",
    "Task_AccountReinstate*", "Task_ACHBHubCreatePIIRequest*",
    "Task_ACHBHubSendPIIRequest*", "Task_ACHCreatePIIRequest*",
    "Task_ACHSendPIIRequest*", "Task_AlertNotification*",
    "Task_BatchNotification", "Task_BatchNotification2",
    "Task_CBRBHubCreatePIIRequest*", "Task_CBRBHubSendPIIRequest*",
    "Task_CBRCreatePIIRequest*", "Task_CBRSendPIIRequest*",
    "Task_CoreAuthAging*", "Task_CoreAuthManualAdminMessage*",
    "Task_CoreAuthRetryAlert*", "Task_CoreIssueRetryAlert*", "Task_DBPD*",
    "Task_ETNP*", "Task_MCSink*", "Task_MCSource*", "Task_MergeAccounts*",
    "Task_MSMQ*", "Task_RetailAuthJobs*", "Task_RewardAutoRedeem*",
    "Task_Rewardnotification*", "Task_TNP*", "Task_UpdateCall*",
    "Task_RewardPromoDetails*", "Task_PendingTxn*", "Task_APJob*",
    "Task_APIQueue*", "Task_CBRManualDF*", "Task_BulkCardFileValidator*",
    "Task_IPMSettlement*", "Task_BulkSOLDAPICall*",
    "Task_keyedhashpopulator*", "Task_BillPayPayment*", "Task_LockBox*",
    "Task_AccountCreation*", "Task_ThirdPartyAlerts*",
    "Amazon Ec2 Launch - Userdata Execution",
]

WEBSITE_LIST = [
    "CoreIssue", "Services", "CoreCredit",
    "WCFServer", "WCF", "CoreCardServices",
]

SERVER_TYPES_LIST = [
    "svc", "iss", "aut", "tnp", "awf", "src",
    "snk", "bat", "wcf", "web", "ew", "kms", "rpd",
]

# Job lists per operation
JOBS_BY_OPERATION = {
    "Process Management": [
        "Stop Processes", "Start Processes", "Restart Processes",
    ],
    "Task Management": [
        "Disable Tasks", "Enable Tasks",
    ],
    "IIS Management": [
        "Stop IIS", "Start IIS", "Reset IIS",
        "Stop and Disable W3SVC", "Enable and Start W3SVC",
        "Stop ScaleService", "Start ScaleService", "Recycle AppPool",
        "Set Connect As - ccgs-app-svc", "Set Connect As - ccgs-app-upg",
        "Set Connect As - ccgs-web-svc", "Set AppPool User - ccgs-app-svc",
        "Set AppPool User - ccgs-app-upg", "Set AppPool User - ccgs-web-svc",
        "Set X-Request-ID", "Disable IIS Logging", "Enable IIS Logging",
        "Set Worker Process 1", "Set Worker Process 4",
        "Set Worker Process 64", "Enable32bitApplication True",
        "Enable32bitApplication False", "IdleTimeoutAction Terminate",
        "IdleTimeoutAction Suspend",
    ],
    "File Management": [
        "Copy APP_SETUP", "Copy WCF_SETUP", "Copy WEB_SETUP",
        "Copy EWEB_SETUP", "Copy KMS_SETUP", "Copy RPD_SETUP",
    ],
}

# Which jobs present the website list in the Process/Task pane
IIS_SITE_JOBS = {
    "Recycle AppPool",
    "Set Connect As - ccgs-app-svc", "Set Connect As - ccgs-app-upg",
    "Set Connect As - ccgs-web-svc", "Set AppPool User - ccgs-app-svc",
    "Set AppPool User - ccgs-app-upg", "Set AppPool User - ccgs-web-svc",
    "Set X-Request-ID", "Disable IIS Logging", "Enable IIS Logging",
    "Set Worker Process 1", "Set Worker Process 4", "Set Worker Process 64",
    "Enable32bitApplication True", "Enable32bitApplication False",
    "IdleTimeoutAction Terminate", "IdleTimeoutAction Suspend",
}

IIS_SERVICE_JOBS = {
    "Stop IIS", "Start IIS", "Reset IIS",
    "Stop and Disable W3SVC", "Enable and Start W3SVC",
}

SCALE_SERVICE_JOBS = {"Stop ScaleService", "Start ScaleService"}

# Folder structures created for each File Management copy job
COPY_FOLDER_STRUCTURE = {
    "APP_SETUP": [
        r"APP_SETUP\DBBSetup\DSLs\CI",
        r"APP_SETUP\DBBSetup\DSLs\CoreAuth",
        r"APP_SETUP\DBBSetup\DSLs\Modularization",
        r"APP_SETUP\DBBSetup\BatchScripts\CoreAuth",
        r"APP_SETUP\DBBSetup\BatchScripts\CoreIssue",
        r"APP_SETUP\DBBSetup\ScaleFiles",
        r"APP_SETUP\CC_runtime",
        r"APP_SETUP\CC_Python",
        r"APP_SETUP\TraceFiles\CoreAuth",
        r"APP_SETUP\TraceFiles\CoreIssue",
        r"APP_SETUP_Archive",
    ],
    "WCF_SETUP": [
        r"WCF_SETUP\WebServer\CoreCardServices",
        r"WCF_SETUP\WebServer\WCF",
        r"WCF_SETUP_Archive",
    ],
    "WEB_SETUP": [
        r"WEB_SETUP\WebServer\DBBScale",
        r"WEB_SETUP\WebServer\ScaleService",
        r"WEB_SETUP\WebServer\DBBWEB",
        r"WEB_SETUP\WebServer\Services",
        r"WEB_SETUP_Archive",
    ],
    "EWEB_SETUP": [
        r"EWEB_SETUP\WebServer\CoreCredit",
        r"EWEB_SETUP_Archive",
    ],
    "KMS_SETUP": [
        r"KMS_SETUP\KMS\KMM",
        r"KMS_SETUP_Archive",
    ],
    "RPD_SETUP": [
        r"RPD_SETUP\ReportDelivery\ReportDelivery",
        r"RPD_SETUP\ReportDelivery\DataFeed",
        r"RPD_SETUP\ReportDelivery\DataReports",
        r"RPD_SETUP\CC_Python",
        r"RPD_SETUP\PlatformCode",
        r"RPD_SETUP_Archive",
    ],
}


# ======================================================================
# AWS HELPERS (subprocess -> aws CLI, same queries as the PS script)
# ======================================================================

def run_aws(args):
    """Run an aws CLI command and return parsed JSON (or None)."""
    try:
        completed = subprocess.run(
            ["aws"] + args,
            capture_output=True,
            text=True,
            check=False,
        )
        if completed.returncode != 0:
            return None, completed.stderr.strip()
        if not completed.stdout.strip():
            return None, "Empty response from aws CLI"
        return json.loads(completed.stdout), None
    except FileNotFoundError:
        return None, "aws CLI not found on PATH"
    except json.JSONDecodeError as exc:
        return None, f"Could not parse aws output: {exc}"
    except Exception as exc:  # noqa: BLE001
        return None, str(exc)


INSTANCE_QUERY = (
    "Reservations[*].Instances[*].{"
    "AvailabilityZone:Placement.AvailabilityZone,"
    "IpAddress:PrivateIpAddress,"
    "Type:InstanceType,"
    "Name:Tags[?Key=='Name']|[0].Value,"
    "Status:State.Name}"
)

SELF_QUERY = (
    "Reservations[*].Instances[*].{"
    "AvailabilityZone:Placement.AvailabilityZone,"
    "IpAddress:PrivateIpAddress,"
    "Type:InstanceType,"
    "Name:Tags[?Key=='Name']|[0].Value,"
    "Status:State.Name,"
    "Environment:Tags[?Key=='environment']|[0].Value,"
    "Stack:Tags[?Key=='stack']|[0].Value,"
    "Attribution:Tags[?Key=='attribution']|[0].Value}"
)


def flatten(nested):
    """aws returns [[{...}]] - flatten to [{...}]."""
    flat = []
    if not nested:
        return flat
    for group in nested:
        if isinstance(group, list):
            flat.extend(group)
        else:
            flat.append(group)
    return flat


def describe_self(region, this_server):
    data, err = run_aws([
        "ec2", "describe-instances",
        "--query", SELF_QUERY,
        "--filters",
        "Name=instance-state-name,Values=running",
        f"Name=tag:Name,Values='{this_server}'",
        "Name=availability-zone,Values='*'",
        "--region", region,
    ])
    if err:
        return None, err
    items = flatten(data)
    if not items:
        return None, f"No running instance found matching tag Name={this_server}"
    return items[0], None


def describe_instances(region, name_pattern, availability_zone="*"):
    data, err = run_aws([
        "ec2", "describe-instances",
        "--query", INSTANCE_QUERY,
        "--filters",
        "Name=instance-state-name,Values=running",
        f"Name=tag:Name,Values='{name_pattern}'",
        f"Name=availability-zone,Values='{availability_zone}'",
        "--region", region,
    ])
    if err:
        return [], err
    return flatten(data), None


# ======================================================================
# SCROLLABLE CHECKBOX LIST WIDGET (replaces CheckedListBox)
# ======================================================================

class CheckList(ttk.Frame):
    def __init__(self, parent, height=110, **kwargs):
        super().__init__(parent, **kwargs)

        self.canvas = tk.Canvas(self, height=height, highlightthickness=1,
                                highlightbackground="#a0a0a0", background="white")
        self.scrollbar = ttk.Scrollbar(self, orient="vertical",
                                       command=self.canvas.yview)
        self.inner = ttk.Frame(self.canvas)

        self.inner.bind(
            "<Configure>",
            lambda e: self.canvas.configure(scrollregion=self.canvas.bbox("all")),
        )
        self.canvas.create_window((0, 0), window=self.inner, anchor="nw")
        self.canvas.configure(yscrollcommand=self.scrollbar.set)

        self.canvas.pack(side="left", fill="both", expand=True)
        self.scrollbar.pack(side="right", fill="y")

        self._vars = {}
        self._on_change = None

        self.canvas.bind("<Enter>", self._bind_wheel)
        self.canvas.bind("<Leave>", self._unbind_wheel)

    def _bind_wheel(self, _event):
        self.canvas.bind_all("<MouseWheel>", self._on_wheel)

    def _unbind_wheel(self, _event):
        self.canvas.unbind_all("<MouseWheel>")

    def _on_wheel(self, event):
        self.canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")

    def set_on_change(self, callback):
        self._on_change = callback

    def set_items(self, items):
        for child in self.inner.winfo_children():
            child.destroy()
        self._vars.clear()

        for item in items:
            var = tk.BooleanVar(value=False)
            chk = ttk.Checkbutton(
                self.inner,
                text=item,
                variable=var,
                command=self._changed,
            )
            chk.pack(anchor="w", padx=4, pady=0)
            self._vars[item] = var

        self.canvas.yview_moveto(0)
        self._changed()

    def _changed(self):
        if self._on_change:
            self._on_change()

    def checked(self):
        return [name for name, var in self._vars.items() if var.get()]

    def clear(self):
        self.set_items([])


# ======================================================================
# MAIN APPLICATION
# ======================================================================

class ConfigOperationsApp(tk.Tk):

    def __init__(self):
        super().__init__()

        self.title("Config Operations")
        self.geometry("980x760")
        self.configure(bg="#ffffff")

        # Runtime state resolved from AWS
        self.this_server = socket.gethostname().lower()
        self.region = None
        self.short_region = None
        self.environment_name = ""
        self.attribution = ""
        self.project_name = ""
        self.environment_stack = ""     # "b" / "g" / ""
        self.copy_source_path = None
        self.copy_source_path_archive = None
        self.server_list = []

        self.output_queue = queue.Queue()
        self.worker = None

        # Session log - written to continuously so a full record survives
        # even if the user closes the app without clicking Save Log.
        self.session_log_path = None
        self._init_session_log()

        self._build_ui()
        self._resolve_environment()
        self.after(100, self._drain_output_queue)

    def _init_session_log(self):
        try:
            os.makedirs(LOG_FOLDER, exist_ok=True)
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            self.session_log_path = os.path.join(
                LOG_FOLDER, f"ConfigOperations_{timestamp}.txt"
            )
        except OSError:
            # Logging to disk is best-effort - the GUI's output pane and
            # the manual Save Log button still work either way.
            self.session_log_path = None

    # ------------------------------------------------------------------
    # UI CONSTRUCTION
    # ------------------------------------------------------------------

    def _build_ui(self):
        pad = {"padx": 8, "pady": 4}

        header = ttk.Frame(self)
        header.pack(fill="x", **pad)

        ttk.Label(header, text="Config Operations",
                  font=("Segoe UI", 16)).pack(side="left")

        self.env_label = ttk.Label(header, text="", font=("Segoe UI", 16))
        self.env_label.pack(side="right")

        body = ttk.Frame(self)
        body.pack(fill="both", expand=True, **pad)

        # ---- Row: Project / POD / Stack ----
        row = ttk.Frame(body)
        row.pack(fill="x", pady=3)

        self.project_label = ttk.Label(row, text="", width=14,
                                       font=("Segoe UI", 10, "bold"))
        self.project_label.pack(side="left")

        ttk.Label(row, text="POD:").pack(side="left", padx=(10, 2))
        self.pod_combo = ttk.Combobox(row, state="readonly", width=22)
        self.pod_combo.pack(side="left")
        self.pod_combo.bind("<<ComboboxSelected>>", lambda e: self._validate())

        ttk.Label(row, text="Stack:").pack(side="left", padx=(16, 2))
        self.stack_combo = ttk.Combobox(row, state="readonly", width=18,
                                        values=STACK_LIST)
        self.stack_combo.pack(side="left")
        self.stack_combo.bind("<<ComboboxSelected>>", self._on_stack_selected)

        # ---- Row: Operation ----
        row = ttk.Frame(body)
        row.pack(fill="x", pady=3)
        ttk.Label(row, text="Operation:", width=14).pack(side="left")
        self.operation_combo = ttk.Combobox(row, state="readonly", width=60,
                                            values=OPERATIONS_LIST)
        self.operation_combo.pack(side="left")
        self.operation_combo.bind("<<ComboboxSelected>>",
                                  self._on_operation_selected)

        # ---- Row: Job ----
        row = ttk.Frame(body)
        row.pack(fill="x", pady=3)
        ttk.Label(row, text="Job:", width=14).pack(side="left")
        self.job_combo = ttk.Combobox(row, state="readonly", width=60)
        self.job_combo.pack(side="left")
        self.job_combo.bind("<<ComboboxSelected>>", self._on_job_selected)

        # ---- Row: Process / Task / Site ----
        row = ttk.Frame(body)
        row.pack(fill="x", pady=3)
        ttk.Label(row, text="Process/Task/Site:",
                  width=16).pack(side="left", anchor="n")
        self.process_list = CheckList(row, height=130)
        self.process_list.pack(side="left", fill="x", expand=True)
        self.process_list.set_on_change(self._validate)

        # ---- Row: AZs ----
        row = ttk.Frame(body)
        row.pack(fill="x", pady=3)
        ttk.Label(row, text="Availability Zones:",
                  width=16).pack(side="left", anchor="n")
        self.az_list = CheckList(row, height=70)
        self.az_list.pack(side="left", fill="x", expand=True)
        self.az_list.set_on_change(self._validate)

        # ---- Row: Server Range ----
        row = ttk.Frame(body)
        row.pack(fill="x", pady=3)
        ttk.Label(row, text="Server Range:", width=16).pack(side="left")

        ttk.Label(row, text="Start").pack(side="left", padx=(10, 2))
        self.range_start = tk.Spinbox(row, from_=0, to=999, width=6,
                                      command=self._validate)
        self.range_start.pack(side="left")
        self.range_start.bind("<KeyRelease>", lambda e: self._validate())

        ttk.Label(row, text="End").pack(side="left", padx=(16, 2))
        self.range_end = tk.Spinbox(row, from_=0, to=999, width=6,
                                    command=self._validate)
        self.range_end.pack(side="left")
        self.range_end.bind("<KeyRelease>", lambda e: self._validate())

        # ---- Row: Server Types ----
        row = ttk.Frame(body)
        row.pack(fill="x", pady=3)
        ttk.Label(row, text="Server Types:",
                  width=16).pack(side="left", anchor="n")
        self.server_type_list = CheckList(row, height=80)
        self.server_type_list.pack(side="left", fill="x", expand=True)
        self.server_type_list.set_items(SERVER_TYPES_LIST)
        self.server_type_list.set_on_change(self._validate)

        # ---- Row: Buttons ----
        row = ttk.Frame(body)
        row.pack(fill="x", pady=8)

        self.preview_button = ttk.Button(row, text="Preview Servers",
                                         command=self._preview_servers)
        self.preview_button.pack(side="left")

        self.submit_button = ttk.Button(row, text="Submit",
                                        command=self._submit, state="disabled")
        self.submit_button.pack(side="left", padx=8)

        ttk.Button(row, text="Reset",
                   command=self._reset_form).pack(side="left", padx=8)

        ttk.Button(row, text="Clear Output",
                   command=self._clear_output).pack(side="left")

        ttk.Button(row, text="Save Log...",
                   command=self._save_log).pack(side="left", padx=8)

        ttk.Label(row, text="Contact : netra.chettri@corecard.com",
                  font=("Segoe UI", 8)).pack(side="right")

        # ---- Output pane ----
        self.output = scrolledtext.ScrolledText(
            body, height=14, font=("Consolas", 9),
            background="#1e1e1e", foreground="#d4d4d4",
            insertbackground="#d4d4d4",
        )
        self.output.pack(fill="both", expand=True, pady=(6, 0))
        self.output.configure(state="disabled")

    # ------------------------------------------------------------------
    # OUTPUT HELPERS
    # ------------------------------------------------------------------

    def log(self, text):
        self.output.configure(state="normal")
        self.output.insert("end", text + "\n")
        self.output.see("end")
        self.output.configure(state="disabled")

        if self.session_log_path:
            try:
                with open(self.session_log_path, "a", encoding="utf-8") as handle:
                    handle.write(text + "\n")
            except OSError:
                pass

    def _clear_output(self):
        self.output.configure(state="normal")
        self.output.delete("1.0", "end")
        self.output.configure(state="disabled")

    def _save_log(self):
        """Let the user export the full output pane to a .txt file."""
        content = self.output.get("1.0", "end").rstrip("\n")

        if not content:
            messagebox.showinfo("Save Log", "There is no output to save yet.")
            return

        default_name = f"ConfigOperations_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"

        path = filedialog.asksaveasfilename(
            title="Save Log As",
            initialfile=default_name,
            defaultextension=".txt",
            filetypes=[("Text files", "*.txt"), ("All files", "*.*")],
        )

        if not path:
            return

        try:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(content + "\n")
        except OSError as exc:
            messagebox.showerror("Save Log", f"Could not save the log:\n\n{exc}")
            return

        self.log(f"Log saved to: {path}")
        messagebox.showinfo("Save Log", f"Log saved to:\n{path}")

    def _reset_form(self):
        """
        Clear every selection back to its initial state, without closing
        the window - equivalent to the original PowerShell script looping
        back to a fresh form (`do {...} while (1 -eq 1)`).
        """
        if self.worker and self.worker.is_alive():
            messagebox.showwarning(
                "Operation running",
                "An operation is still running. Please wait for it to "
                "finish before resetting the form."
            )
            return

        self.pod_combo.set("")
        self.stack_combo.set("")
        self.operation_combo.set("")

        self.job_combo.set("")
        self.job_combo.configure(values=[])

        self.process_list.clear()
        self.az_list.clear()

        self.range_start.delete(0, "end")
        self.range_start.insert(0, "0")
        self.range_end.delete(0, "end")
        self.range_end.insert(0, "0")

        self.server_type_list.set_items(SERVER_TYPES_LIST)

        self.copy_source_path = None
        self.copy_source_path_archive = None
        self.server_list = []

        self.submit_button.configure(state="disabled")
        self.preview_button.configure(state="normal")

        self.log("")
        self.log("Form reset.")

    def _drain_output_queue(self):
        try:
            while True:
                line = self.output_queue.get_nowait()
                if line is None:
                    self.preview_button.configure(state="normal")
                    self._validate()
                else:
                    self.log(line.rstrip())
        except queue.Empty:
            pass
        self.after(100, self._drain_output_queue)

    # ------------------------------------------------------------------
    # ENVIRONMENT RESOLUTION (replaces the top of the PS script)
    # ------------------------------------------------------------------

    def _resolve_environment(self):
        if self.session_log_path:
            self.log(f"Session log: {self.session_log_path}")

        self.log(f"Local server: {self.this_server}")

        if "e1" in self.this_server:
            self.region = "us-east-1"
            self.short_region = "e1"
        elif "w2" in self.this_server:
            self.region = "us-west-2"
            self.short_region = "w2"
        else:
            messagebox.showerror(
                "Region not detected",
                "Hostname does not contain 'e1' or 'w2' - cannot determine "
                "AWS region."
            )
            self.log("ERROR: could not determine region from hostname.")
            return

        self.log(f"Region: {self.region} ({self.short_region})")

        info, err = describe_self(self.region, self.this_server)
        if err:
            messagebox.showerror("AWS lookup failed", err)
            self.log(f"ERROR: {err}")
            return

        self.environment_name = (info.get("Environment") or "").lower()
        self.attribution = (info.get("Attribution") or "").lower()
        self.project_name = self.attribution.upper()

        self.env_label.configure(text=self.environment_name.upper())
        self.project_label.configure(text=self.project_name)

        self.log(f"Environment: {self.environment_name}")
        self.log(f"Attribution: {self.attribution}")

        # POD list depends on attribution (same rule as the PS script)
        if self.attribution == "cookie":
            pods = ["COOKIE-POD2", "COOKIE-POD4"]
        else:
            pods = ["POD3-JAZZ"]
        self.pod_combo.configure(values=pods)

        # Reset the working copy directory
        self._reset_copy_directory()

    def _reset_copy_directory(self):
        if os.path.exists(COPY_FILE_DIRECTORY):
            try:
                shutil.rmtree(COPY_FILE_DIRECTORY)
            except OSError as exc:
                messagebox.showwarning(
                    "Copy folder",
                    f"Unable to delete {COPY_FILE_DIRECTORY}\n"
                    f"Please remove it manually.\n\n{exc}"
                )
                self.log(f"WARNING: could not remove {COPY_FILE_DIRECTORY}: {exc}")

    # ------------------------------------------------------------------
    # EVENT HANDLERS
    # ------------------------------------------------------------------

    def _on_stack_selected(self, _event=None):
        selection = self.stack_combo.get()
        if selection == "Blue":
            self.environment_stack = "b"
        elif selection == "Green":
            self.environment_stack = "g"
        else:
            self.environment_stack = ""

        self.log(f"Stack: {selection} -> '{self.environment_stack}'")
        self._load_availability_zones()
        self._validate()

    def _load_availability_zones(self):
        self.az_list.clear()

        pattern = (
            f"*{AVAILABILITY_ZONES_DEFAULT_SERVER_TYPE}"
            f"{self.short_region}{self.environment_name}"
            f"{self.environment_stack}*"
        )
        instances, err = describe_instances(self.region, pattern)
        if err:
            self.log(f"ERROR loading AZs: {err}")
            return

        zones = sorted({
            i.get("AvailabilityZone") for i in instances
            if i.get("AvailabilityZone")
        })
        self.az_list.set_items(zones)
        self.log(f"Availability zones found: {', '.join(zones) or '(none)'}")

    def _on_operation_selected(self, _event=None):
        operation = self.operation_combo.get()
        self.job_combo.set("")
        self.job_combo.configure(values=JOBS_BY_OPERATION.get(operation, []))
        self.process_list.clear()
        self.range_start.delete(0, "end")
        self.range_start.insert(0, "0")
        self.range_end.delete(0, "end")
        self.range_end.insert(0, "0")
        self._validate()

    def _on_job_selected(self, _event=None):
        job = self.job_combo.get()
        self.process_list.clear()

        if job in ("Stop Processes", "Restart Processes"):
            self.process_list.set_items(PROCESSES_LIST)

        elif job in ("Start Processes", "Disable Tasks", "Enable Tasks"):
            self.process_list.set_items(TASKS_LIST)

        elif job in IIS_SERVICE_JOBS:
            self.process_list.set_items(["IIS"])

        elif job in SCALE_SERVICE_JOBS:
            self.process_list.set_items(["ScaleService"])

        elif job in IIS_SITE_JOBS:
            self.process_list.set_items(WEBSITE_LIST)

        elif job.startswith("Copy "):
            self._prepare_copy_folders(job)

        self._validate()

    def _prepare_copy_folders(self, job):
        """Recreate the copy folder structure, then let the user drop files in."""
        setup_name = job.split(" ", 1)[1]           # e.g. APP_SETUP
        self.copy_source_path = os.path.join(COPY_FILE_DIRECTORY, setup_name)
        self.copy_source_path_archive = self.copy_source_path + "_Archive"

        existing = [
            path for path in (self.copy_source_path, self.copy_source_path_archive)
            if os.path.exists(path)
        ]

        if existing:
            answer = messagebox.askyesno(
                "Folders already exist",
                "These folders already exist:\n\n"
                + "\n".join(existing)
                + "\n\nDelete them and recreate blank folders?"
            )
            if answer:
                for path in existing:
                    try:
                        shutil.rmtree(path)
                    except OSError as exc:
                        messagebox.showerror(
                            "Delete failed",
                            f"Could not delete {path}\n\n{exc}"
                        )
                        return
            else:
                return

        for relative in COPY_FOLDER_STRUCTURE.get(setup_name, []):
            os.makedirs(os.path.join(COPY_FILE_DIRECTORY, relative), exist_ok=True)

        messagebox.showinfo(
            "Copy files",
            f"Copy the required files into:\n\n{self.copy_source_path}\n\n"
            "Press OK to open the folder."
        )

        try:
            os.startfile(self.copy_source_path)     # noqa: S606 (Windows only)
        except Exception as exc:                     # noqa: BLE001
            self.log(f"Could not open folder: {exc}")

        self.process_list.set_items([
            f"Confirm Files Copied to Path ? - {self.copy_source_path}"
        ])

    # ------------------------------------------------------------------
    # VALIDATION
    # ------------------------------------------------------------------

    def _range_values(self):
        try:
            start = int(self.range_start.get() or 0)
        except ValueError:
            start = 0
        try:
            end = int(self.range_end.get() or 0)
        except ValueError:
            end = 0
        return start, end

    def _validate(self, _event=None):
        _start, end = self._range_values()

        ready = all([
            self.pod_combo.get(),
            self.stack_combo.get(),
            self.operation_combo.get(),
            self.job_combo.get(),
            self.process_list.checked(),
            self.az_list.checked(),
            self.server_type_list.checked(),
            end != 0,
        ])

        self.submit_button.configure(state="normal" if ready else "disabled")

    # ------------------------------------------------------------------
    # SERVER DISCOVERY (replaces the ServerList block in the PS script)
    # ------------------------------------------------------------------

    def _serial_for(self, name, server_type):
        """Extract the numeric suffix used for range filtering."""
        if server_type == "bat":
            marker = self.environment_name
        else:
            marker = f"{self.environment_name}{self.environment_stack}"

        if marker not in name:
            return None

        tail = name.split(marker, 1)[1]
        digits = "".join(ch for ch in tail if ch.isdigit())
        if not digits:
            return None
        return int(digits)

    def _build_server_list(self):
        start, end = self._range_values()
        servers = []

        for server_type in self.server_type_list.checked():
            self.log(f"--- Server type: {server_type} ---")

            for az in self.az_list.checked():
                if server_type == "bat":
                    pattern = (f"*{server_type}{self.short_region}"
                               f"{self.environment_name}*")
                else:
                    pattern = (f"*{server_type}{self.short_region}"
                               f"{self.environment_name}"
                               f"{self.environment_stack}*")

                instances, err = describe_instances(self.region, pattern, az)
                if err:
                    self.log(f"ERROR querying {server_type} in {az}: {err}")
                    continue

                for instance in instances:
                    name = instance.get("Name") or ""
                    serial = self._serial_for(name, server_type)
                    if serial is None:
                        continue
                    if start <= serial <= end:
                        servers.append(name)
                        self.log(f"  {name}  ({az})  serial={serial}")

        return sorted(set(servers))

    def _preview_servers(self):
        if not self.az_list.checked() or not self.server_type_list.checked():
            messagebox.showwarning(
                "Selection incomplete",
                "Select at least one availability zone and one server type."
            )
            return

        self.log("")
        self.log("Resolving server list...")
        self.server_list = self._build_server_list()

        if not self.server_list:
            self.log("No servers matched the given criteria.")
            messagebox.showinfo("No servers",
                                "No servers matched the given criteria.")
        else:
            self.log(f"Total servers: {len(self.server_list)}")

    # ------------------------------------------------------------------
    # SUBMIT -> POWERSHELL BACKEND
    # ------------------------------------------------------------------

    def _submit(self):
        operation = self.operation_combo.get()
        job = self.job_combo.get()
        targets = self.process_list.checked()

        self.log("")
        self.log("Resolving server list...")
        self.server_list = self._build_server_list()

        if not self.server_list:
            messagebox.showerror(
                "No servers",
                "No servers matched the given criteria. Please adjust the "
                "selection and try again."
            )
            return

        summary = (
            f"PROJECT : {self.project_name}\n"
            f"POD     : {self.pod_combo.get()}\n"
            f"STACK   : {self.stack_combo.get()}\n"
            f"OPERATION: {operation}\n"
            f"JOB     : {job}\n"
            f"TARGETS : {', '.join(targets)}\n"
            f"AZs     : {', '.join(self.az_list.checked())}\n"
            f"RANGE   : {self.range_start.get()} - {self.range_end.get()}\n"
            f"TYPES   : {', '.join(self.server_type_list.checked())}\n\n"
            f"SERVERS ({len(self.server_list)}):\n"
            + "\n".join(self.server_list)
            + "\n\nProceed?"
        )

        if not messagebox.askokcancel("Verify and confirm", summary):
            self.log("Cancelled by user.")
            return

        copy_path_s3 = ""
        if job.startswith("Copy "):
            copy_path_s3 = self._package_and_upload(job)
            if copy_path_s3 is None:
                return

        self.submit_button.configure(state="disabled")
        self.preview_button.configure(state="disabled")

        self.worker = threading.Thread(
            target=self._run_backend,
            args=(operation, job, targets, list(self.server_list), copy_path_s3),
            daemon=True,
        )
        self.worker.start()

    def _package_and_upload(self, job):
        """Zip the copy folder and push it to S3 (File Management jobs)."""
        setup_name = job.split(" ", 1)[1]
        archive_dir = os.path.join(COPY_FILE_DIRECTORY, setup_name + "_Archive")
        os.makedirs(archive_dir, exist_ok=True)

        zip_base = os.path.join(archive_dir, setup_name)
        source_dir = os.path.join(COPY_FILE_DIRECTORY, setup_name)

        self.log(f"Compressing {source_dir} ...")
        try:
            zip_path = shutil.make_archive(zip_base, "zip", source_dir)
        except Exception as exc:                     # noqa: BLE001
            messagebox.showerror("Compress failed", str(exc))
            self.log(f"ERROR compressing: {exc}")
            return None

        pod_token = self.pod_combo.get().split("-")[1].lower()
        s3_path = (
            f"s3://corecard-{pod_token}-{self.environment_name}-"
            f"{self.region}-config-files/COPYFILES/{setup_name}.zip"
        )

        self.log(f"Uploading to {s3_path} ...")
        subprocess.run(["aws", "s3", "rm", s3_path],
                       capture_output=True, text=True, check=False)
        result = subprocess.run(["aws", "s3", "cp", zip_path, s3_path],
                                capture_output=True, text=True, check=False)

        if result.returncode != 0:
            messagebox.showerror("S3 upload failed", result.stderr.strip())
            self.log(f"ERROR uploading: {result.stderr.strip()}")
            return None

        self.log("Upload complete.")
        return s3_path

    def _run_backend(self, operation, job, targets, servers, copy_path_s3):
        """Invoke the PowerShell backend and stream its output into the GUI."""
        if not os.path.exists(BACKEND_SCRIPT):
            self.output_queue.put(
                f"ERROR: backend script not found: {BACKEND_SCRIPT}")
            self.output_queue.put(None)
            return

        command = [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", BACKEND_SCRIPT,
            "-EnvironmentName", self.environment_name,
            "-Operation", operation,
            "-Job", job,
            "-ServerList", ",".join(servers),
        ]

        if targets:
            command += ["-ProcessTasks", ",".join(targets)]
        if copy_path_s3:
            command += ["-CopyPathS3", copy_path_s3]

        self.output_queue.put("")
        self.output_queue.put("=" * 62)
        self.output_queue.put("Running PowerShell backend...")
        self.output_queue.put("=" * 62)

        report_file = None

        try:
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )

            for line in process.stdout:
                stripped = line.strip()
                if stripped.startswith("REPORT_FILE::"):
                    report_file = stripped.split("::", 1)[1]
                    self.output_queue.put(f"Report: {report_file}")
                else:
                    self.output_queue.put(line)

            process.wait()
            self.output_queue.put("")
            self.output_queue.put(f"Backend exited with code {process.returncode}")

        except Exception as exc:                     # noqa: BLE001
            self.output_queue.put(f"ERROR running backend: {exc}")

        finally:
            if report_file and os.path.exists(report_file):
                try:
                    os.startfile(report_file)        # noqa: S606 (Windows only)
                except Exception:                    # noqa: BLE001
                    pass
            self.output_queue.put(None)


# ======================================================================
# ENTRY POINT
# ======================================================================

def main():
    if not sys.platform.startswith("win"):
        print("This tool targets Windows (PowerShell remoting, IIS, os.startfile).")

    app = ConfigOperationsApp()
    app.mainloop()


if __name__ == "__main__":
    main()
