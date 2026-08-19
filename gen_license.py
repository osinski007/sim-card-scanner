import tkinter as tk
from tkinter import messagebox
import hashlib
import getpass
import subprocess

def get_hardware_id():
    ids = []
    
    try:
        result = subprocess.run(
            'wmic baseboard get serialnumber',
            capture_output=True, text=True, shell=True
        )
        for line in result.stdout.strip().split('\n'):
            line = line.strip()
            if line and line != "SerialNumber":
                ids.append(line)
    except:
        pass
    
    try:
        result = subprocess.run(
            'wmic diskdrive get serialnumber',
            capture_output=True, text=True, shell=True
        )
        for line in result.stdout.strip().split('\n'):
            line = line.strip()
            if line and line != "SerialNumber":
                ids.append(line)
    except:
        pass
    
    try:
        result = subprocess.run(
            'wmic cpu get processorid',
            capture_output=True, text=True, shell=True
        )
        for line in result.stdout.strip().split('\n'):
            line = line.strip()
            if line and line != "ProcessorId":
                ids.append(line)
    except:
        pass
    
    try:
        result = subprocess.run(
            'wmic path win32_networkadapterconfiguration where ipenabled=true get macaddress',
            capture_output=True, text=True, shell=True
        )
        for line in result.stdout.strip().split('\n'):
            line = line.strip()
            if line and len(line) == 17:
                ids.append(line.replace("-", ""))
    except:
        pass
    
    code_str = "".join(ids)
    if not code_str:
        code_str = getpass.getuser()
    
    return hashlib.md5(code_str.encode()).hexdigest()[:16].upper()

def generate_key(machine_code):
    chars = "0123456789ABCDEFGHJKLMNPQRSTUVWXYZ"
    key = ""
    seed = int(machine_code, 16)
    for i in range(20):
        seed = (seed * 1103515245 + 12345) & 0x7fffffff
        key += chars[seed % len(chars)]
        if i in [4, 9, 14]:
            key += "-"
    return key

# GUI
root = tk.Tk()
root.title("授权码生成器")
root.geometry("450x300")
root.resizable(False, False)

root.update_idletasks()
x = (root.winfo_screenwidth() // 2) - 225
y = (root.winfo_screenheight() // 2) - 150
root.geometry(f'450x300+{x}+{y}')

frame = tk.Frame(root, padx=20, pady=20)
frame.pack(fill="both", expand=True)

tk.Label(frame, text="授权码生成器", font=("Arial", 14, "bold")).pack(pady=10)

tk.Label(frame, text="输入机器码:", font=("", 10)).pack(pady=(10, 0))
input_var = tk.StringVar()
input_entry = tk.Entry(frame, textvariable=input_var, font=("Courier", 12), justify="center")
input_entry.pack(pady=5)
input_entry.focus()

result_var = tk.StringVar()

def generate():
    mc = input_var.get().strip().upper()
    if not mc:
        messagebox.showwarning("提示", "请输入机器码！")
        return
    
    if len(mc) != 16:
        messagebox.showwarning("提示", "机器码应为16位！")
        return
    
    try:
        int(mc, 16)
    except:
        messagebox.showwarning("提示", "机器码格式无效！")
        return
    
    key = generate_key(mc)
    result_var.set(key)
    result_entry.configure(state="normal")
    result_entry.delete(0, "end")
    result_entry.insert(0, key)
    result_entry.configure(state="readonly")

def copy_result():
    key = result_var.get()
    if key:
        root.clipboard_clear()
        root.clipboard_append(key)
        messagebox.showinfo("提示", "已复制到剪贴板！")

tk.Button(frame, text="生成授权码", command=generate, bg="#2196F3", fg="white", width=25, font=("", 12)).pack(pady=10)

tk.Label(frame, text="生成的授权码:", font=("", 10)).pack(pady=(10, 0))
result_entry = tk.Entry(frame, textvariable=result_var, font=("Courier", 12), fg="green", 
                      justify="center", state="readonly")
result_entry.pack()

tk.Button(frame, text="复制授权码", command=copy_result, bg="#4CAF50", fg="white", width=25, font=("", 12)).pack(pady=10)

root.mainloop()