#!/usr/bin/env python3
"""Thin VMware Guest Operations helper for nested ESXi bootstrap.

Talks to the metal ESXi/vCenter SOAP SDK (not SSH into the guest). Used by
VIM_SSH.pm when VMware Tools reports toolsOk so VCL can reconfigure vmk0 and
install root authorized_keys before wait_for_ssh.

Backends (first success wins):
  1. pyVmomi (pyVim.connect / pyVmomi.vim) if installed
  2. stdlib vim25 SOAP (http.client + xml) — no extra packages

Passwords are read from the environment, not argv:
  VCL_VMHOST_PASSWORD  host/vCenter login
  VCL_GUEST_PASSWORD   in-guest NamePasswordAuthentication
"""

from __future__ import print_function

import argparse
import http.client
import os
import ssl
import sys
import time
import xml.etree.ElementTree as ET
from urllib.parse import urlparse
from xml.sax.saxutils import escape


NS_SOAP = "http://schemas.xmlsoap.org/soap/envelope/"
NS_VIM = "urn:vim25"


class GuestOpsError(Exception):
    pass


def _eprint(*args):
    print(*args, file=sys.stderr)


def _xml_text(value):
    if value is None:
        return ""
    return escape(str(value), {'"': "&quot;", "'": "&apos;"})


# ---------------------------------------------------------------------------
# pyVmomi backend
# ---------------------------------------------------------------------------

def _try_pyvmomi():
    try:
        from pyVim.connect import SmartConnect  # noqa: F401
        from pyVmomi import vim  # noqa: F401
        return True
    except Exception:
        return False


def _pyvmomi_connect(host, username, password, port):
    from pyVim.connect import SmartConnect

    kwargs = {
        "host": host,
        "user": username,
        "pwd": password,
        "port": port,
    }
    ctx = ssl._create_unverified_context()
    try:
        return SmartConnect(sslContext=ctx, **kwargs)
    except TypeError:
        # Older pyVmomi used disableSslCertValidation
        try:
            return SmartConnect(disableSslCertValidation=True, **kwargs)
        except TypeError:
            ssl._create_default_https_context = ssl._create_unverified_context
            return SmartConnect(**kwargs)


def _pyvmomi_find_vm(si, vm_id, vmx_path):
    from pyVmomi import vim

    content = si.RetrieveContent()
    if vmx_path:
        try:
            search = content.searchIndex
            for datacenter in content.rootFolder.childEntity:
                if not hasattr(datacenter, "vmFolder"):
                    continue
                vm = search.FindByDatastorePath(datacenter, vmx_path)
                if vm:
                    return vm, content
        except Exception as exc:
            _eprint("pyVmomi FindByDatastorePath failed: %s" % exc)

    container = content.viewManager.CreateContainerView(
        content.rootFolder, [vim.VirtualMachine], True
    )
    try:
        for vm in container.view:
            moref = getattr(vm, "_moId", None) or str(vm).split(":")[-1].rstrip("'")
            if vm_id and str(moref) == str(vm_id):
                return vm, content
            if vmx_path and getattr(vm.summary.config, "vmPathName", "") == vmx_path:
                return vm, content
    finally:
        container.Destroy()
    raise GuestOpsError("unable to find VM (vm_id=%s vmx=%s)" % (vm_id, vmx_path))


def _pyvmomi_wait_tools(si, vm_id, vmx_path, timeout):
    vm, _content = _pyvmomi_find_vm(si, vm_id, vmx_path)
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        try:
            vm.Reload()
        except Exception:
            pass
        guest = vm.guest
        running = str(getattr(guest, "toolsRunningStatus", "") or "")
        status = str(getattr(guest, "toolsStatus", "") or "")
        ip_address = str(getattr(guest, "ipAddress", "") or "")
        last = "toolsRunningStatus=%s toolsStatus=%s ipAddress=%s" % (
            running,
            status,
            ip_address,
        )
        if running.endswith("guestToolsRunning") or running == "guestToolsRunning":
            if "NotRunning" not in status and "toolsNotRunning" not in status:
                print("OK")
                print(last)
                return 0
        time.sleep(5)
    raise GuestOpsError("timed out waiting for guest tools: %s" % last)


def _replace_star_host(url, host, port):
    # InitiateFileTransfer* returns https://*:443/guestFile?...
    parsed = urlparse(url)
    if parsed.hostname in (None, "*", ""):
        netloc = host
        if port and port not in (80, 443):
            netloc = "%s:%s" % (host, port)
        url = "%s://%s%s" % (parsed.scheme or "https", netloc, parsed.path)
        if parsed.query:
            url += "?" + parsed.query
    return url


def _http_put(url, data, host, port):
    url = _replace_star_host(url, host, port)
    parsed = urlparse(url)
    conn_port = parsed.port or (443 if parsed.scheme == "https" else 80)
    ctx = ssl._create_unverified_context()
    conn = http.client.HTTPSConnection(parsed.hostname, conn_port, context=ctx, timeout=120)
    path = parsed.path
    if parsed.query:
        path += "?" + parsed.query
    body = data if isinstance(data, bytes) else data.encode("utf-8")
    conn.request("PUT", path, body=body, headers={"Content-Type": "application/octet-stream"})
    resp = conn.getresponse()
    payload = resp.read()
    conn.close()
    if resp.status not in (200, 201, 204):
        raise GuestOpsError("file PUT failed HTTP %s: %s" % (resp.status, payload[:300]))


def _http_get(url, host, port):
    url = _replace_star_host(url, host, port)
    parsed = urlparse(url)
    conn_port = parsed.port or (443 if parsed.scheme == "https" else 80)
    ctx = ssl._create_unverified_context()
    conn = http.client.HTTPSConnection(parsed.hostname, conn_port, context=ctx, timeout=120)
    path = parsed.path
    if parsed.query:
        path += "?" + parsed.query
    conn.request("GET", path)
    resp = conn.getresponse()
    payload = resp.read()
    conn.close()
    if resp.status != 200:
        raise GuestOpsError("file GET failed HTTP %s: %s" % (resp.status, payload[:300]))
    return payload


def _pyvmomi_creds(guest_user, guest_password):
    from pyVmomi import vim

    return vim.vm.guest.NamePasswordAuthentication(
        username=guest_user, password=guest_password, interactiveSession=False
    )


def _pyvmomi_write(si, vm_id, vmx_path, guest_user, guest_password, guest_path, data, host, port):
    from pyVmomi import vim

    vm, content = _pyvmomi_find_vm(si, vm_id, vmx_path)
    creds = _pyvmomi_creds(guest_user, guest_password)
    fm = content.guestOperationsManager.fileManager
    if not isinstance(data, bytes):
        data = data.encode("utf-8")
    url = fm.InitiateFileTransferToGuest(
        vm,
        creds,
        guest_path,
        vim.vm.guest.FileManager.FileAttributes(),
        len(data),
        True,
    )
    _http_put(url, data, host, port)


def _pyvmomi_read(si, vm_id, vmx_path, guest_user, guest_password, guest_path, host, port):
    vm, content = _pyvmomi_find_vm(si, vm_id, vmx_path)
    creds = _pyvmomi_creds(guest_user, guest_password)
    fm = content.guestOperationsManager.fileManager
    info = fm.InitiateFileTransferFromGuest(vm, creds, guest_path)
    url = getattr(info, "url", info)
    return _http_get(url, host, port)


def _pyvmomi_run(si, vm_id, vmx_path, guest_user, guest_password, script_bytes, host, port, timeout):
    from pyVmomi import vim

    remote_script = "/tmp/vcl-mn-guestops.sh"
    remote_out = "/tmp/vcl-mn-guestops.out"
    wrapper = (
        "#!/bin/sh\n"
        "/bin/sh %s > %s 2>&1\n"
        "echo __VCL_GUESTOPS_RC__$? >> %s\n" % (remote_script, remote_out, remote_out)
    )
    _pyvmomi_write(
        si, vm_id, vmx_path, guest_user, guest_password, remote_script, script_bytes, host, port
    )
    _pyvmomi_write(
        si, vm_id, vmx_path, guest_user, guest_password, "/tmp/vcl-mn-guestops-wrap.sh", wrapper, host, port
    )

    vm, content = _pyvmomi_find_vm(si, vm_id, vmx_path)
    creds = _pyvmomi_creds(guest_user, guest_password)
    pm = content.guestOperationsManager.processManager
    spec = vim.vm.guest.ProcessManager.ProgramSpec(
        programPath="/bin/sh",
        arguments="/tmp/vcl-mn-guestops-wrap.sh",
        workingDirectory="/",
    )
    pid = pm.StartProgramInGuest(vm, creds, spec)
    deadline = time.time() + timeout
    while time.time() < deadline:
        procs = pm.ListProcessesInGuest(vm, creds, [int(pid)])
        if procs and getattr(procs[0], "endTime", None):
            break
        time.sleep(2)
    else:
        raise GuestOpsError("guest program pid %s did not exit within %ss" % (pid, timeout))

    output = _pyvmomi_read(
        si, vm_id, vmx_path, guest_user, guest_password, remote_out, host, port
    )
    text = output.decode("utf-8", "replace")
    print("OK")
    sys.stdout.write(text)
    if not text.endswith("\n"):
        print()
    return 0


# ---------------------------------------------------------------------------
# stdlib SOAP backend
# ---------------------------------------------------------------------------

class VimSoap(object):
    def __init__(self, url, username, password):
        parsed = urlparse(url if "://" in url else "https://%s/sdk" % url)
        self.scheme = parsed.scheme or "https"
        self.host = parsed.hostname
        self.port = parsed.port or 443
        self.path = parsed.path or "/sdk"
        self.username = username
        self.password = password
        self.cookie = None
        self.ctx = ssl._create_unverified_context()

    def invoke(self, inner_xml):
        body = (
            '<?xml version="1.0" encoding="UTF-8"?>'
            '<soapenv:Envelope xmlns:soapenv="%s" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:vim="%s">'
            "<soapenv:Body>%s</soapenv:Body></soapenv:Envelope>"
        ) % (NS_SOAP, NS_VIM, inner_xml)
        conn = http.client.HTTPSConnection(self.host, self.port, context=self.ctx, timeout=120)
        headers = {
            "Content-Type": 'text/xml; charset="utf-8"',
            "SOAPAction": "urn:vim25/6.0",
        }
        if self.cookie:
            headers["Cookie"] = self.cookie
        conn.request("POST", self.path, body=body.encode("utf-8"), headers=headers)
        resp = conn.getresponse()
        payload = resp.read()
        set_cookie = resp.getheader("Set-Cookie")
        if set_cookie:
            # Keep vmware_soap_session
            self.cookie = set_cookie.split(";", 1)[0]
        conn.close()
        text = payload.decode("utf-8", "replace")
        if resp.status != 200 or "Fault>" in text or ":Fault" in text:
            snippet = text[:800].replace("\n", " ")
            raise GuestOpsError("SOAP %s failed HTTP %s: %s" % (inner_xml[:40], resp.status, snippet))
        return text

    def login(self):
        xml = (
            "<vim:RetrieveServiceContent>"
            '<vim:_this type="ServiceInstance">ServiceInstance</vim:_this>'
            "</vim:RetrieveServiceContent>"
        )
        self.invoke(xml)
        xml = (
            "<vim:Login>"
            '<vim:_this type="SessionManager">SessionManager</vim:_this>'
            "<vim:userName>%s</vim:userName>"
            "<vim:password>%s</vim:password>"
            "</vim:Login>"
        ) % (_xml_text(self.username), _xml_text(self.password))
        self.invoke(xml)

    def _tag_text(self, xml_text, local_name):
        # Namespace-agnostic: match <foo:name> or <name>
        start = xml_text.find("<%s>" % local_name)
        if start < 0:
            # prefixed
            idx = xml_text.find(":%s>" % local_name)
            if idx < 0:
                return ""
            start = xml_text.rfind("<", 0, idx)
        gt = xml_text.find(">", start)
        lt = xml_text.find("<", gt + 1)
        if gt < 0 or lt < 0:
            return ""
        return xml_text[gt + 1 : lt]

    def _attr_val(self, xml_text, local_name, attr):
        # <name attr="value"> or <name type="VirtualMachine">11</name>
        needle = ":%s " % local_name
        idx = xml_text.find(needle)
        if idx < 0:
            idx = xml_text.find("<%s " % local_name)
        if idx < 0:
            return ""
        end = xml_text.find(">", idx)
        tag = xml_text[idx:end]
        key = '%s="' % attr
        a = tag.find(key)
        if a < 0:
            return ""
        a += len(key)
        b = tag.find('"', a)
        return tag[a:b]

    def retrieve_props(self, type_name, moref, paths):
        path_xml = "".join("<vim:pathSet>%s</vim:pathSet>" % _xml_text(p) for p in paths)
        xml = (
            "<vim:RetrieveProperties>"
            '<vim:_this type="PropertyCollector">propertyCollector</vim:_this>'
            "<vim:specSet>"
            "<vim:propSet>"
            "<vim:type>%s</vim:type>"
            "%s"
            "</vim:propSet>"
            "<vim:objectSet>"
            '<vim:obj type="%s">%s</vim:obj>'
            "<vim:skip>false</vim:skip>"
            "</vim:objectSet>"
            "</vim:specSet>"
            "</vim:RetrieveProperties>"
        ) % (_xml_text(type_name), path_xml, _xml_text(type_name), _xml_text(moref))
        return self.invoke(xml)

    def find_vm_moref(self, vm_id, vmx_path):
        if vm_id:
            return str(vm_id)
        if not vmx_path:
            raise GuestOpsError("vm-id or vmx-path is required")
        xml = (
            "<vim:FindByDatastorePath>"
            '<vim:_this type="SearchIndex">SearchIndex</vim:_this>'
            '<vim:datacenter type="Datacenter">ha-datacenter</vim:datacenter>'
            "<vim:path>%s</vim:path>"
            "</vim:FindByDatastorePath>"
        ) % _xml_text(vmx_path)
        body = self.invoke(xml)
        moref = self._tag_text(body, "returnval")
        if not moref:
            raise GuestOpsError("FindByDatastorePath returned no VM for %s" % vmx_path)
        return moref

    def wait_tools(self, vm_moref, timeout):
        deadline = time.time() + timeout
        last = ""
        while time.time() < deadline:
            body = self.retrieve_props(
                "VirtualMachine",
                vm_moref,
                [
                    "guest.toolsRunningStatus",
                    "guest.toolsStatus",
                    "guest.ipAddress",
                ],
            )
            running = ""
            status = ""
            ip_address = ""
            # val tags follow name tags in ObjectContent
            try:
                root = ET.fromstring(body)
            except ET.ParseError:
                running = self._extract_val_after(body, "guest.toolsRunningStatus")
                status = self._extract_val_after(body, "guest.toolsStatus")
                ip_address = self._extract_val_after(body, "guest.ipAddress")
            else:
                current = ""
                for elem in root.iter():
                    tag = elem.tag.split("}")[-1]
                    if tag == "name" and elem.text:
                        current = elem.text
                    elif tag == "val" and elem.text is not None:
                        if current == "guest.toolsRunningStatus":
                            running = elem.text
                        elif current == "guest.toolsStatus":
                            status = elem.text
                        elif current == "guest.ipAddress":
                            ip_address = elem.text
            last = "toolsRunningStatus=%s toolsStatus=%s ipAddress=%s" % (
                running,
                status,
                ip_address,
            )
            if running.endswith("guestToolsRunning") or running == "guestToolsRunning":
                if "NotRunning" not in (status or "") and "toolsNotRunning" not in (status or ""):
                    print("OK")
                    print(last)
                    return 0
            time.sleep(5)
        raise GuestOpsError("timed out waiting for guest tools: %s" % last)

    def _extract_val_after(self, xml_text, name):
        marker = ">%s<" % name
        idx = xml_text.find(marker)
        if idx < 0:
            return ""
        val_idx = xml_text.find("<", idx + 1)
        # skip to next val
        val_open = xml_text.find("val", idx)
        if val_open < 0:
            return ""
        gt = xml_text.find(">", val_open)
        lt = xml_text.find("<", gt + 1)
        return xml_text[gt + 1 : lt] if gt > 0 and lt > gt else ""

    def _auth_xml(self, guest_user, guest_password):
        return (
            '<vim:auth xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
            'xsi:type="NamePasswordAuthentication">'
            "<vim:interactiveSession>false</vim:interactiveSession>"
            "<vim:username>%s</vim:username>"
            "<vim:password>%s</vim:password>"
            "</vim:auth>"
        ) % (_xml_text(guest_user), _xml_text(guest_password))

    def _gom_managers(self):
        body = self.retrieve_props(
            "GuestOperationsManager",
            "guestOperationsManager",
            ["processManager", "fileManager"],
        )
        process_mgr = "guestOperationsProcessManager"
        file_mgr = "guestOperationsFileManager"
        try:
            root = ET.fromstring(body)
            current = ""
            for elem in root.iter():
                tag = elem.tag.split("}")[-1]
                if tag == "name" and elem.text:
                    current = elem.text
                elif tag == "val" and elem.text:
                    if current == "processManager":
                        process_mgr = elem.text
                    elif current == "fileManager":
                        file_mgr = elem.text
        except ET.ParseError:
            pass
        return process_mgr, file_mgr

    def write_file(self, vm_moref, guest_user, guest_password, guest_path, data):
        if not isinstance(data, bytes):
            data = data.encode("utf-8")
        _process_mgr, file_mgr = self._gom_managers()
        xml = (
            "<vim:InitiateFileTransferToGuest>"
            '<vim:_this type="GuestFileManager">%s</vim:_this>'
            '<vim:vm type="VirtualMachine">%s</vim:vm>'
            "%s"
            "<vim:guestFilePath>%s</vim:guestFilePath>"
            "<vim:fileAttributes></vim:fileAttributes>"
            "<vim:fileSize>%s</vim:fileSize>"
            "<vim:overwrite>true</vim:overwrite>"
            "</vim:InitiateFileTransferToGuest>"
        ) % (
            _xml_text(file_mgr),
            _xml_text(vm_moref),
            self._auth_xml(guest_user, guest_password),
            _xml_text(guest_path),
            len(data),
        )
        body = self.invoke(xml)
        url = self._tag_text(body, "returnval")
        if not url:
            raise GuestOpsError("InitiateFileTransferToGuest returned no URL")
        _http_put(url, data, self.host, self.port)

    def read_file(self, vm_moref, guest_user, guest_password, guest_path):
        _process_mgr, file_mgr = self._gom_managers()
        xml = (
            "<vim:InitiateFileTransferFromGuest>"
            '<vim:_this type="GuestFileManager">%s</vim:_this>'
            '<vim:vm type="VirtualMachine">%s</vim:vm>'
            "%s"
            "<vim:guestFilePath>%s</vim:guestFilePath>"
            "</vim:InitiateFileTransferFromGuest>"
        ) % (
            _xml_text(file_mgr),
            _xml_text(vm_moref),
            self._auth_xml(guest_user, guest_password),
            _xml_text(guest_path),
        )
        body = self.invoke(xml)
        url = ""
        try:
            root = ET.fromstring(body)
            for elem in root.iter():
                if elem.tag.split("}")[-1] == "url" and elem.text:
                    url = elem.text
                    break
        except ET.ParseError:
            url = self._tag_text(body, "url")
        if not url:
            raise GuestOpsError("InitiateFileTransferFromGuest returned no URL")
        return _http_get(url, self.host, self.port)

    def run_script(self, vm_moref, guest_user, guest_password, script_bytes, timeout):
        remote_script = "/tmp/vcl-mn-guestops.sh"
        remote_wrap = "/tmp/vcl-mn-guestops-wrap.sh"
        remote_out = "/tmp/vcl-mn-guestops.out"
        wrapper = (
            "#!/bin/sh\n"
            "/bin/sh %s > %s 2>&1\n"
            "echo __VCL_GUESTOPS_RC__$? >> %s\n" % (remote_script, remote_out, remote_out)
        )
        self.write_file(vm_moref, guest_user, guest_password, remote_script, script_bytes)
        self.write_file(vm_moref, guest_user, guest_password, remote_wrap, wrapper)

        process_mgr, _file_mgr = self._gom_managers()
        xml = (
            "<vim:StartProgramInGuest>"
            '<vim:_this type="GuestProcessManager">%s</vim:_this>'
            '<vim:vm type="VirtualMachine">%s</vim:vm>'
            "%s"
            "<vim:spec>"
            "<vim:programPath>/bin/sh</vim:programPath>"
            "<vim:arguments>%s</vim:arguments>"
            "<vim:workingDirectory>/</vim:workingDirectory>"
            "</vim:spec>"
            "</vim:StartProgramInGuest>"
        ) % (
            _xml_text(process_mgr),
            _xml_text(vm_moref),
            self._auth_xml(guest_user, guest_password),
            _xml_text(remote_wrap),
        )
        body = self.invoke(xml)
        pid = self._tag_text(body, "returnval")
        if not pid:
            raise GuestOpsError("StartProgramInGuest returned no pid")

        deadline = time.time() + timeout
        while time.time() < deadline:
            list_xml = (
                "<vim:ListProcessesInGuest>"
                '<vim:_this type="GuestProcessManager">%s</vim:_this>'
                '<vim:vm type="VirtualMachine">%s</vim:vm>'
                "%s"
                "<vim:pids>%s</vim:pids>"
                "</vim:ListProcessesInGuest>"
            ) % (
                _xml_text(process_mgr),
                _xml_text(vm_moref),
                self._auth_xml(guest_user, guest_password),
                _xml_text(pid),
            )
            list_body = self.invoke(list_xml)
            if "endTime" in list_body and "xsi:nil" not in list_body.split("endTime", 1)[-1][:80]:
                # Heuristic: an endTime element with a timestamp
                if "<endTime" in list_body and "1970" not in list_body:
                    break
                if "</endTime>" in list_body:
                    break
            time.sleep(2)
        else:
            raise GuestOpsError("guest program pid %s did not exit within %ss" % (pid, timeout))

        output = self.read_file(vm_moref, guest_user, guest_password, remote_out)
        text = output.decode("utf-8", "replace")
        print("OK")
        sys.stdout.write(text)
        if not text.endswith("\n"):
            print()
        return 0


def _parse_url(url):
    parsed = urlparse(url if "://" in url else "https://%s/sdk" % url)
    host = parsed.hostname
    port = parsed.port or 443
    return host, port, parsed.geturl() if "://" in url else "https://%s/sdk" % url


def _read_file(path):
    with open(path, "rb") as fh:
        return fh.read()


def main(argv=None):
    parser = argparse.ArgumentParser(description="VCL nested ESXi guest operations helper")
    parser.add_argument("action", choices=["wait-tools", "run", "write", "read"])
    parser.add_argument("--url", required=True, help="https://esxi-host/sdk")
    parser.add_argument("--username", required=True, help="metal host / vCenter username")
    parser.add_argument("--vm-id", dest="vm_id", default="", help="VirtualMachine MoRef / vim-cmd vmid")
    parser.add_argument("--vmx-path", dest="vmx_path", default="", help='datastore path e.g. "[ds] vm/vm.vmx"')
    parser.add_argument("--timeout", type=int, default=480)
    parser.add_argument("--guest-user", dest="guest_user", default="root")
    parser.add_argument("--guest-path", dest="guest_path", default="")
    parser.add_argument("--file", dest="file_path", default="")
    parser.add_argument("--script-file", dest="script_file", default="")
    args = parser.parse_args(argv)

    host_password = os.environ.get("VCL_VMHOST_PASSWORD", "")
    guest_password = os.environ.get("VCL_GUEST_PASSWORD", "")
    if not host_password:
        raise GuestOpsError("VCL_VMHOST_PASSWORD is not set")

    host, port, url = _parse_url(args.url)

    use_pyvmomi = _try_pyvmomi()
    si = None
    if use_pyvmomi:
        try:
            si = _pyvmomi_connect(host, args.username, host_password, port)
        except Exception as exc:
            _eprint("pyVmomi connect failed, falling back to SOAP: %s" % exc)
            use_pyvmomi = False
            si = None

    if args.action == "wait-tools":
        if use_pyvmomi and si:
            return _pyvmomi_wait_tools(si, args.vm_id, args.vmx_path, args.timeout)
        soap = VimSoap(url, args.username, host_password)
        soap.login()
        moref = soap.find_vm_moref(args.vm_id, args.vmx_path)
        return soap.wait_tools(moref, args.timeout)

    if not guest_password:
        raise GuestOpsError("VCL_GUEST_PASSWORD is not set")

    if args.action == "write":
        if not args.guest_path or not args.file_path:
            raise GuestOpsError("write requires --guest-path and --file")
        data = _read_file(args.file_path)
        if use_pyvmomi and si:
            _pyvmomi_write(
                si, args.vm_id, args.vmx_path, args.guest_user, guest_password, args.guest_path, data, host, port
            )
            print("OK")
            return 0
        soap = VimSoap(url, args.username, host_password)
        soap.login()
        moref = soap.find_vm_moref(args.vm_id, args.vmx_path)
        soap.write_file(moref, args.guest_user, guest_password, args.guest_path, data)
        print("OK")
        return 0

    if args.action == "read":
        if not args.guest_path:
            raise GuestOpsError("read requires --guest-path")
        if use_pyvmomi and si:
            data = _pyvmomi_read(
                si, args.vm_id, args.vmx_path, args.guest_user, guest_password, args.guest_path, host, port
            )
            print("OK")
            sys.stdout.buffer.write(data)
            return 0
        soap = VimSoap(url, args.username, host_password)
        soap.login()
        moref = soap.find_vm_moref(args.vm_id, args.vmx_path)
        data = soap.read_file(moref, args.guest_user, guest_password, args.guest_path)
        print("OK")
        sys.stdout.buffer.write(data)
        return 0

    if args.action == "run":
        if not args.script_file:
            raise GuestOpsError("run requires --script-file")
        script = _read_file(args.script_file)
        if use_pyvmomi and si:
            return _pyvmomi_run(
                si,
                args.vm_id,
                args.vmx_path,
                args.guest_user,
                guest_password,
                script,
                host,
                port,
                args.timeout,
            )
        soap = VimSoap(url, args.username, host_password)
        soap.login()
        moref = soap.find_vm_moref(args.vm_id, args.vmx_path)
        return soap.run_script(moref, args.guest_user, guest_password, script, args.timeout)

    raise GuestOpsError("unknown action %s" % args.action)


if __name__ == "__main__":
    try:
        sys.exit(main() or 0)
    except GuestOpsError as exc:
        print("ERROR")
        print(str(exc))
        sys.exit(2)
    except Exception as exc:
        print("ERROR")
        print("%s: %s" % (type(exc).__name__, exc))
        sys.exit(2)
