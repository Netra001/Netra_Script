"""
======================================================================
PlatformCode Delete - Python GUI Front End
======================================================================
Replaces the interactive Read-Host prompts with a GUI.

 - GUI              : Python / Tkinter
 - AWS discovery    : aws CLI via subprocess
 - Remote execution : PlatformDelete-Backend.ps1 (PowerShell backend)

Environment rule (unchanged from the PowerShell version):
 - PROD:      must pick exactly ONE Availability Zone (radio buttons -
              structurally prevents an "all zones" mistake).
 - NON-PROD (dev/qa/patqa/patuat/uat/perf): AZs are shown as
              checkboxes - any number, including all of them, may be
              selected in one shot.
======================================================================
"""

import json
import os
import queue
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
    beside_exe = os.path.join(
        os.path.dirname(os.path.abspath(sys.executable)), filename
    )
    if getattr(sys, "frozen", False) and os.path.exists(beside_exe):
        return beside_exe

    base = getattr(
        sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__))
    )
    return os.path.join(base, filename)


BACKEND_SCRIPT = resource_path("PlatformDelete-Backend.ps1")

LOG_FOLDER = r"C:\Temp"

VALID_ENVIRONMENTS = ["dev", "qa", "patqa", "patuat", "uat", "perf", "prod"]

SERVER_TYPES = ["bat", "svc", "iss", "aut", "src", "snk", "tnp", "awf"]

AZ_DEFAULT_SERVER_TYPE = "tnp"


# ======================================================================
# AWS HELPERS
# ======================================================================

def run_aws(args):
    try:
        completed = subprocess.run(
            ["aws"] + args, capture_output=True, text=True, check=False
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

INSTANCE_QUERY = (
    "Reservations[*].Instances[*].{"
    "AvailabilityZone:Placement.AvailabilityZone,"
    "IpAddress:PrivateIpAddress,"
    "Type:InstanceType,"
    "Name:Tags[?Key=='Name']|[0].Value,"
    "Status:State.Name}"
)


def flatten(nested):
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
# SCROLLABLE CHECKBOX LIST WIDGET
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

    def set_items(self, items, checked_by_default=False):
        for child in self.inner.winfo_children():
            child.destroy()
        self._vars.clear()

        for item in items:
            var = tk.BooleanVar(value=checked_by_default)
            chk = ttk.Checkbutton(
                self.inner, text=item, variable=var, command=self._changed,
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

    def check_all(self):
        for var in self._vars.values():
            var.set(True)
        self._changed()

    def clear(self):
        self.set_items([])


# ======================================================================
# MAIN APPLICATION
# ======================================================================

class PlatformDeleteApp(tk.Tk):

    def __init__(self):
        super().__init__()

        self.title("PlatformCode Delete")
        self.geometry("900x760")
        self.configure(bg="#ffffff")

        self.this_server = socket.gethostname().lower()
        self.region = None
        self.short_region = None
        self.environment_name = ""
        self.environment_attribution = ""
        self.is_prod = False
        self.environment_category = ""
        self.pod_name = ""
        self.server_list = []

        self.output_queue = queue.Queue()
        self.worker = None

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
                LOG_FOLDER, f"PlatformDelete_{timestamp}.txt"
            )
        except OSError:
            self.session_log_path = None

    # ------------------------------------------------------------------
    # UI CONSTRUCTION
    # ------------------------------------------------------------------

    def _build_ui(self):
        pad = {"padx": 8, "pady": 4}

        header = ttk.Frame(self)
        header.pack(fill="x", **pad)
        ttk.Label(header, text="PlatformCode Delete",
                  font=("Segoe UI", 16)).pack(side="left")
        self.env_label = ttk.Label(header, text="", font=("Segoe UI", 14))
        self.env_label.pack(side="right")

        body = ttk.Frame(self)
        body.pack(fill="both", expand=True, **pad)

        # ---- Bifurcated summary ----
        summary = ttk.LabelFrame(body, text="Environment Summary")
        summary.pack(fill="x", pady=4)

        self.summary_text = ttk.Label(summary, text="Resolving environment...",
                                      font=("Segoe UI", 10), justify="left")
        self.summary_text.pack(anchor="w", padx=8, pady=6)

        # ---- POD ----
        row = ttk.Frame(body)
        row.pack(fill="x", pady=3)
        ttk.Label(row, text="POD:", width=16).pack(side="left")
        self.pod_combo = ttk.Combobox(row, state="readonly", width=25)
        self.pod_combo.pack(side="left")
        self.pod_combo.bind("<<ComboboxSelected>>", self._on_pod_selected)

        # ---- AZ selection (frame contents swapped based on PROD/non-PROD) ----
        self.az_frame_label = ttk.Label(body, text="Availability Zone(s):")
        self.az_frame_label.pack(anchor="w", pady=(8, 0))
        self.az_container = ttk.Frame(body)
        self.az_container.pack(fill="x", pady=3)
        self.az_widget = None  # set in _render_az_widget

        # ---- Server Types ----
        ttk.Label(body, text="Server Types:").pack(anchor="w", pady=(8, 0))
        self.server_type_list = CheckList(body, height=90)
        self.server_type_list.pack(fill="x", pady=3)
        self.server_type_list.set_items(SERVER_TYPES, checked_by_default=False)
        self.server_type_list.set_on_change(self._validate)

        # ---- Deletion condition ----
        ttk.Label(body, text="Deletion Condition:").pack(anchor="w", pady=(8, 0))
        cond_frame = ttk.Frame(body)
        cond_frame.pack(fill="x", pady=3)

        self.condition_var = tk.StringVar(value="")
        ttk.Radiobutton(
            cond_frame, text="1. Delete CC-Runtime AND shmem Memory file (both at once)",
            variable=self.condition_var, value="1", command=self._validate,
        ).pack(anchor="w")
        ttk.Radiobutton(
            cond_frame, text="2. Delete a SpecificFile folder (D:\\BKP\\1)",
            variable=self.condition_var, value="2", command=self._validate,
        ).pack(anchor="w")

        # ---- Buttons ----
        row = ttk.Frame(body)
        row.pack(fill="x", pady=8)

        self.preview_button = ttk.Button(row, text="Preview Servers",
                                         command=self._preview_servers, state="disabled")
        self.preview_button.pack(side="left")

        self.submit_button = ttk.Button(row, text="Submit",
                                        command=self._submit, state="disabled")
        self.submit_button.pack(side="left", padx=8)

        ttk.Button(row, text="Reset", command=self._reset_form).pack(side="left", padx=8)
        ttk.Button(row, text="Clear Output", command=self._clear_output).pack(side="left")
        ttk.Button(row, text="Save Log...", command=self._save_log).pack(side="left", padx=8)

        # ---- Output pane ----
        self.output = scrolledtext.ScrolledText(
            body, height=16, font=("Consolas", 9),
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
        content = self.output.get("1.0", "end").rstrip("\n")
        if not content:
            messagebox.showinfo("Save Log", "There is no output to save yet.")
            return

        default_name = f"PlatformDelete_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"
        path = filedialog.asksaveasfilename(
            title="Save Log As", initialfile=default_name, defaultextension=".txt",
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
    # ENVIRONMENT RESOLUTION
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
                "Hostname does not contain 'e1' or 'w2' - cannot determine AWS region."
            )
            self.log("ERROR: could not determine region from hostname.")
            return

        info, err = describe_self(self.region, self.this_server)
        if err:
            messagebox.showerror("AWS lookup failed", err)
            self.log(f"ERROR: {err}")
            return

        self.environment_name = (info.get("Environment") or "").lower()
        self.environment_attribution = (info.get("Attribution") or "").lower()
        self.environment_stack = ((info.get("Stack") or "").lower()[:1])

        if self.environment_name not in VALID_ENVIRONMENTS:
            messagebox.showerror(
                "Unrecognized environment",
                f"Unrecognized environment: '{self.environment_name}'.\n"
                f"Expected one of: {', '.join(VALID_ENVIRONMENTS)}"
            )
            self.log(f"ERROR: unrecognized environment '{self.environment_name}'.")
            return

        self.is_prod = (self.environment_name == "prod")
        self.environment_category = "PROD" if self.is_prod else "NON-PROD"

        self.env_label.configure(text=self.environment_name.upper())
        self.log(f"Environment: {self.environment_name} ({self.environment_category})")

        if self.environment_attribution == "cookie":
            self.pod_combo.configure(values=["POD2", "POD4"])
        elif self.environment_attribution == "jazz":
            self.pod_combo.configure(values=["jazz"])
            self.pod_combo.set("jazz")
            self._on_pod_selected()
        else:
            messagebox.showerror(
                "Invalid attribution",
                f"Invalid Environment Attribution: '{self.environment_attribution}'"
            )
            self.log(f"ERROR: invalid environment attribution '{self.environment_attribution}'.")

    # ------------------------------------------------------------------
    # POD -> bifurcated summary -> AZ widget
    # ------------------------------------------------------------------

    def _on_pod_selected(self, _event=None):
        selection = self.pod_combo.get()
        self.pod_name = "pod2" if selection == "POD2" else ("pod4" if selection == "POD4" else "jazz")

        summary = (
            f"POD Selected        : {self.pod_name}\n"
            f"Environment          : {self.environment_name.upper()}\n"
            f"Environment Category : {self.environment_category}"
        )
        self.summary_text.configure(text=summary)

        self.log("")
        self.log("=" * 40)
        self.log(f" POD Selected        : {self.pod_name}")
        self.log(f" Environment          : {self.environment_name.upper()}")
        self.log(f" Environment Category : {self.environment_category}")
        self.log("=" * 40)

        if self.is_prod:
            self.log("PROD environment - only ONE Availability Zone may be selected.")
        else:
            self.log("Non-PROD environment - any number of Availability Zones (including all) may be selected.")

        self._load_availability_zones()

    def _load_availability_zones(self):
        pattern = (
            f"*{AZ_DEFAULT_SERVER_TYPE}{self.short_region}"
            f"{self.environment_name}{self.environment_stack}*"
        )
        instances, err = describe_instances(self.region, pattern)
        if err:
            self.log(f"ERROR loading AZs: {err}")
            return

        zones = sorted({
            i.get("AvailabilityZone") for i in instances if i.get("AvailabilityZone")
        })
        self.log(f"Availability zones found: {', '.join(zones) or '(none)'}")
        self._render_az_widget(zones)

    def _render_az_widget(self, zones):
        for child in self.az_container.winfo_children():
            child.destroy()

        if self.is_prod:
            # PROD: one concrete AZ only; never expose the wildcard option.
            zones = [zone for zone in zones if zone != "*"]
            self.az_var = tk.StringVar(value="")
            for zone in zones:
                ttk.Radiobutton(
                    self.az_container, text=zone, variable=self.az_var,
                    value=zone, command=self._validate,
                ).pack(anchor="w")
            self.az_widget = ("radio", self.az_var)
        else:
            # Non-PROD: checkbox list, any number (including all) selectable.
            az_list = CheckList(self.az_container, height=90)
            az_list.pack(fill="x")
            az_list.set_items(zones)
            az_list.set_on_change(self._validate)

            select_all_btn = ttk.Button(
                self.az_container, text="Select All Zones",
                command=az_list.check_all,
            )
            select_all_btn.pack(anchor="w", pady=(4, 0))

            self.az_widget = ("checklist", az_list)

        self._validate()

    def _selected_azs(self):
        if not self.az_widget:
            return []
        kind, widget = self.az_widget
        if kind == "radio":
            value = widget.get()
            return [value] if value else []
        else:
            return widget.checked()

    # ------------------------------------------------------------------
    # VALIDATION
    # ------------------------------------------------------------------

    def _az_selection_is_valid(self):
        azs = self._selected_azs()
        return bool(azs) and (not self.is_prod or len(azs) == 1 and azs[0] != "*")

    def _validate(self, _event=None):
        ready = all([
            self.pod_name,
            self._az_selection_is_valid(),
            self.server_type_list.checked(),
            self.condition_var.get(),
        ])
        state = "normal" if ready else "disabled"
        self.submit_button.configure(state=state)
        self.preview_button.configure(state=state)

    # ------------------------------------------------------------------
    # SERVER DISCOVERY
    # ------------------------------------------------------------------

    def _build_server_list(self):
        azs = self._selected_azs()
        server_types = self.server_type_list.checked()
        servers = []

        for server_type in server_types:
            self.log(f"--- Server type: {server_type} ---")

            for az in azs:
                pattern = (
                    f"*{server_type}{self.short_region}"
                    f"{self.environment_name}{self.environment_stack}*"
                )
                instances, err = describe_instances(self.region, pattern, az)
                if err:
                    self.log(f"ERROR querying {server_type} in {az}: {err}")
                    continue

                for instance in instances:
                    name = instance.get("Name") or ""
                    if name:
                        servers.append(name)
                        self.log(f"  {name}  ({az})")

        return sorted(set(servers))

    def _preview_servers(self):
        self.log("")
        self.log("Resolving server list...")
        self.server_list = self._build_server_list()

        if not self.server_list:
            self.log("No servers matched the given criteria.")
            messagebox.showinfo("No servers", "No servers matched the given criteria.")
        else:
            self.log(f"Total servers: {len(self.server_list)}")

    # ------------------------------------------------------------------
    # RESET
    # ------------------------------------------------------------------

    def _reset_form(self):
        if self.worker and self.worker.is_alive():
            messagebox.showwarning(
                "Operation running",
                "An operation is still running. Please wait for it to finish before resetting."
            )
            return

        self.pod_combo.set("")
        self.pod_name = ""
        self.summary_text.configure(text="Select a POD to see the environment summary.")

        for child in self.az_container.winfo_children():
            child.destroy()
        self.az_widget = None

        self.server_type_list.set_items(SERVER_TYPES, checked_by_default=False)
        self.condition_var.set("")
        self.server_list = []

        self.submit_button.configure(state="disabled")
        self.preview_button.configure(state="disabled")

        self.log("")
        self.log("Form reset.")

    # ------------------------------------------------------------------
    # SUBMIT -> POWERSHELL BACKEND
    # ------------------------------------------------------------------

    def _submit(self):
        azs = self._selected_azs()
        condition = self.condition_var.get()

        if not self._az_selection_is_valid():
            messagebox.showerror(
                "Invalid Availability Zone",
                "PROD requires exactly one specific Availability Zone."
                if self.is_prod else
                "Please select at least one Availability Zone.",
            )
            return

        self.log("")
        self.log("Resolving server list...")
        self.server_list = self._build_server_list()

        if not self.server_list:
            messagebox.showerror(
                "No servers",
                "No servers matched the given criteria. Please adjust the selection and try again."
            )
            return

        az_label = f"{', '.join(azs)} ({len(azs)} zone{'s' if len(azs) != 1 else ''})"
        condition_label = (
            "Delete CC-Runtime AND shmem Memory file (both at once)"
            if condition == "1" else
            "Delete a SpecificFile folder (D:\\BKP\\1)"
        )

        summary = (
            f"ENVIRONMENT : {self.environment_name.upper()} ({self.environment_category})\n"
            f"POD         : {self.pod_name}\n"
            f"AZ(s)       : {az_label}\n"
            f"CONDITION   : {condition_label}\n"
            f"SERVER TYPES: {', '.join(self.server_type_list.checked())}\n\n"
            f"SERVERS ({len(self.server_list)}):\n"
            + "\n".join(self.server_list)
            + "\n\nThis will permanently delete files/folders on the servers above. Proceed?"
        )

        if not messagebox.askokcancel("Verify and confirm", summary, icon="warning"):
            self.log("Cancelled by user.")
            return

        self.submit_button.configure(state="disabled")
        self.preview_button.configure(state="disabled")

        self.worker = threading.Thread(
            target=self._run_backend,
            args=(condition, az_label, list(self.server_list)),
            daemon=True,
        )
        self.worker.start()

    def _run_backend(self, condition, az_label, servers):
        if not os.path.exists(BACKEND_SCRIPT):
            self.output_queue.put(f"ERROR: backend script not found: {BACKEND_SCRIPT}")
            self.output_queue.put(None)
            return

        command = [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", BACKEND_SCRIPT,
            "-EnvironmentName", self.environment_name,
            "-EnvironmentCategory", self.environment_category,
            "-PODName", self.pod_name,
            "-AvailabilityZoneLabel", az_label,
            "-ConditionSelected", condition,
            "-ServerList", *servers,
        ]

        self.output_queue.put("")
        self.output_queue.put("=" * 62)
        self.output_queue.put("Running PowerShell backend...")
        self.output_queue.put("=" * 62)

        report_file = None

        try:
            process = subprocess.Popen(
                command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1,
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

        except Exception as exc:  # noqa: BLE001
            self.output_queue.put(f"ERROR running backend: {exc}")

        finally:
            if report_file and os.path.exists(report_file):
                try:
                    os.startfile(report_file)  # noqa: S606 (Windows only)
                except Exception:  # noqa: BLE001
                    pass
            self.output_queue.put(None)


# ======================================================================
# ENTRY POINT
# ======================================================================

def main():
    if not sys.platform.startswith("win"):
        print("This tool targets Windows (PowerShell remoting, os.startfile).")

    app = PlatformDeleteApp()
    app.mainloop()


if __name__ == "__main__":
    main()
