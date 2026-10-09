"""Bounded Windows evaluation processes; owned descendants are assigned before resume."""
from __future__ import annotations
import ctypes
from ctypes import wintypes as W
import os
from pathlib import Path
import subprocess
import time

class BasicLimits(ctypes.Structure):
    _fields_=[('process_time',ctypes.c_longlong),('job_time',ctypes.c_longlong),('flags',W.DWORD),('minimum',ctypes.c_size_t),('maximum',ctypes.c_size_t),('active_limit',W.DWORD),('affinity',ctypes.c_size_t),('priority',W.DWORD),('scheduling',W.DWORD)]
class IoCounters(ctypes.Structure):
    _fields_=[(name,ctypes.c_ulonglong) for name in ('read_ops','write_ops','other_ops','read_bytes','write_bytes','other_bytes')]
class ExtendedLimits(ctypes.Structure):
    _fields_=[('basic',BasicLimits),('io',IoCounters),('process_memory',ctypes.c_size_t),('job_memory',ctypes.c_size_t),('peak_process',ctypes.c_size_t),('peak_job',ctypes.c_size_t)]
class Accounting(ctypes.Structure):
    _fields_=[(name,ctypes.c_longlong) for name in ('user','kernel','period_user','period_kernel')]+[(name,W.DWORD) for name in ('faults','total','active','terminated')]

def _outputs_released(kernel,paths)->bool:
    """Require exclusive read handles after our output streams have closed."""
    kernel.CreateFileW.argtypes=[W.LPCWSTR,W.DWORD,W.DWORD,ctypes.c_void_p,W.DWORD,W.DWORD,W.HANDLE]
    kernel.CreateFileW.restype=W.HANDLE
    handles=[]
    try:
        for path in paths:
            name=os.path.abspath(path)
            if not name.startswith('\\\\?\\'):
                name='\\\\?\\UNC\\'+name[2:] if name.startswith('\\\\') else '\\\\?\\'+name
            handle=kernel.CreateFileW(name,0x80000000,0,None,3,0x80,None)
            if not handle or handle==W.HANDLE(-1).value:return False
            handles.append(handle)
        return True
    finally:
        for handle in handles:kernel.CloseHandle(handle)

def _wait_for_cleanup(kernel,job,paths,seconds=5)->bool:
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        account=Accounting()
        if not kernel.QueryInformationJobObject(job,1,ctypes.byref(account),ctypes.sizeof(account),None):return False
        if account.active==0 and _outputs_released(kernel,paths):return True
        time.sleep(.05)
    return False

def run_owned(command:list[str],cwd:Path,stdout:Path,stderr:Path,*,env:dict|None=None,seconds:int=600)->dict:
    if os.name!='nt': raise RuntimeError('Workflow execution requires the supported Windows job-object runner')
    k=ctypes.WinDLL('kernel32',use_last_error=True)
    k.CreateJobObjectW.argtypes=[ctypes.c_void_p,W.LPCWSTR];k.CreateJobObjectW.restype=W.HANDLE
    k.SetInformationJobObject.argtypes=[W.HANDLE,ctypes.c_int,ctypes.c_void_p,W.DWORD]
    k.AssignProcessToJobObject.argtypes=[W.HANDLE,W.HANDLE]
    k.TerminateJobObject.argtypes=[W.HANDLE,W.UINT]
    k.QueryInformationJobObject.argtypes=[W.HANDLE,ctypes.c_int,ctypes.c_void_p,W.DWORD,ctypes.c_void_p]
    k.CloseHandle.argtypes=[W.HANDLE]
    job=k.CreateJobObjectW(None,None)
    if not job: raise ctypes.WinError(ctypes.get_last_error())
    process=None;start=time.monotonic();status='launch_failed';clean=False;exit_code=None
    try:
        limits=ExtendedLimits();limits.basic.flags=0x2000
        if not k.SetInformationJobObject(job,9,ctypes.byref(limits),ctypes.sizeof(limits)): raise ctypes.WinError(ctypes.get_last_error())
        with stdout.open('xb') as out,stderr.open('xb') as err:
            process=subprocess.Popen(command,cwd=cwd,env=env,stdout=out,stderr=err,stdin=subprocess.DEVNULL,creationflags=0x08000000|0x00000004)
            if not k.AssignProcessToJobObject(job,W.HANDLE(int(process._handle))): raise ctypes.WinError(ctypes.get_last_error())
            resume=ctypes.WinDLL('ntdll').NtResumeProcess;resume.argtypes=[W.HANDLE];resume.restype=ctypes.c_long
            if resume(W.HANDLE(int(process._handle)))!=0: raise RuntimeError('Could not resume the assigned evaluation process')
            status='completed'
            while process.poll() is None:
                if time.monotonic()-start>=seconds: status='timed_out';break
                if stdout.stat().st_size+stderr.stat().st_size>16777216: status='output_limit';break
                time.sleep(.1)
            if status=='completed': exit_code=process.wait()
            k.TerminateJobObject(job,1)
            process.wait(timeout=10)
        # Empty job accounting can precede release of inherited output handles.
        # Close our own streams before checking that retained evidence is free.
        clean=_wait_for_cleanup(k,job,(stdout,stderr))
        # Check final output after cleanup as well as while running, so a last
        # descendant write cannot turn an oversized trace into successful evidence.
        if stdout.stat().st_size+stderr.stat().st_size>16777216:
            status='output_limit';exit_code=None
    finally:
        k.TerminateJobObject(job,1)
        if process is not None and process.poll() is None: process.kill();process.wait(timeout=10)
        k.CloseHandle(job)
    return {'status':status,'exit_code':exit_code,'cleanup_verified':clean,'elapsed_seconds':str(time.monotonic()-start),'console_bytes':stdout.stat().st_size+stderr.stat().st_size}
