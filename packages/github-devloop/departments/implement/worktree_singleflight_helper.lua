return [=[
import fcntl
import hashlib
import os
import pathlib
import secrets
import select
import socket
import stat
import sys

PROTOCOL = "FKST_IMPLEMENTATION_WORKTREE_SINGLEFLIGHT:v1"
CONTROL_ROOT = pathlib.Path("/tmp") / f"fkst-implementation-singleflight-{os.getuid()}"
CONTROL_TIMEOUT_SECONDS = 10


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def control_root():
    CONTROL_ROOT.mkdir(parents=False, exist_ok=True)
    details = CONTROL_ROOT.lstat()
    if not stat.S_ISDIR(details.st_mode) or details.st_uid != os.getuid():
        fail("worktree single-flight control root has an unsafe owner or type")
    return CONTROL_ROOT


def server_path(lock_name):
    digest = hashlib.sha256(os.fsencode(lock_name)).hexdigest()[:32]
    return control_root() / f"{digest}.sock"


class OwnerWatcher:
    def __init__(self, owner_pid):
        self.owner_pid = owner_pid
        self.pidfd = None
        self.queue = None
        if sys.platform.startswith("linux"):
            if not hasattr(os, "pidfd_open"):
                raise RuntimeError("worktree single-flight requires os.pidfd_open on Linux")
            self.pidfd = os.pidfd_open(owner_pid)
        elif hasattr(select, "kqueue"):
            self.queue = select.kqueue()
            process_event = select.kevent(
                owner_pid,
                filter=select.KQ_FILTER_PROC,
                flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_ONESHOT,
                fflags=select.KQ_NOTE_EXIT,
            )
            self.queue.control([process_event], 0, 0)
        else:
            raise RuntimeError("worktree single-flight has no kernel owner watcher on this platform")

    def close(self):
        if self.pidfd is not None:
            os.close(self.pidfd)
            self.pidfd = None
        if self.queue is not None:
            self.queue.close()
            self.queue = None

    def wait_for_release_or_owner_exit(self, server, token):
        if self.pidfd is not None:
            poller = select.poll()
            poller.register(self.pidfd, select.POLLIN | select.POLLHUP | select.POLLERR)
            poller.register(server.fileno(), select.POLLIN | select.POLLHUP | select.POLLERR)
            while True:
                for descriptor, _ in poller.poll():
                    if descriptor == self.pidfd:
                        return
                    if release_requested(server, token):
                        return
        socket_event = select.kevent(
            server.fileno(),
            filter=select.KQ_FILTER_READ,
            flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE,
        )
        self.queue.control([socket_event], 0, 0)
        while True:
            event = self.queue.control(None, 1, None)[0]
            if event.filter == select.KQ_FILTER_PROC:
                return
            if event.filter == select.KQ_FILTER_READ and release_requested(server, token):
                return


def release_requested(server, token):
    message, address = server.recvfrom(4096)
    if not address:
        return False
    if secrets.compare_digest(message, token.encode("ascii")):
        server.sendto(("RELEASED:" + token).encode("ascii"), address)
        return True
    server.sendto(b"ERROR:token-mismatch", address)
    return False


def redirect_standard_streams():
    descriptor = os.open(os.devnull, os.O_RDWR)
    try:
        for target in (0, 1, 2):
            os.dup2(descriptor, target)
    finally:
        if descriptor > 2:
            os.close(descriptor)


def run_guardian(lock_handle, server, socket_name, token, owner_pid, ready_fd):
    watcher = None
    ready = False
    try:
        redirect_standard_streams()
        watcher = OwnerWatcher(owner_pid)
        os.write(ready_fd, f"{PROTOCOL}:ACQUIRED:{token}\n".encode("ascii"))
        os.close(ready_fd)
        ready_fd = -1
        ready = True
        watcher.wait_for_release_or_owner_exit(server, token)
    except BaseException as exc:
        if not ready and ready_fd >= 0:
            detail = str(exc).replace("\r", " ").replace("\n", " ")[:512]
            os.write(ready_fd, f"{PROTOCOL}:ERROR:{detail}\n".encode("utf-8", "replace"))
    finally:
        if ready_fd >= 0:
            os.close(ready_fd)
        if watcher is not None:
            watcher.close()
        server.close()
        lock_handle.close()
        try:
            socket_name.unlink()
        except FileNotFoundError:
            pass
    os._exit(0)


def acquire(lock_name, owner_pid):
    pathlib.Path(lock_name).parent.mkdir(parents=True, exist_ok=True)
    lock_handle = open(lock_name, "a+", encoding="utf-8")
    try:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock_handle.close()
        print(f"{PROTOCOL}:BUSY:locked")
        return

    socket_name = server_path(lock_name)
    try:
        socket_name.unlink()
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        server.bind(str(socket_name))
        token = secrets.token_hex(16)
        read_fd, write_fd = os.pipe()
        try:
            child_pid = os.fork()
        except BaseException:
            os.close(read_fd)
            os.close(write_fd)
            raise
        if child_pid == 0:
            os.close(read_fd)
            run_guardian(lock_handle, server, socket_name, token, owner_pid, write_fd)

        os.close(write_fd)
        server.close()
        lock_handle.close()
        response = os.read(read_fd, 4096).decode("utf-8", "replace").strip()
        os.close(read_fd)
        if response.startswith(f"{PROTOCOL}:ERROR:"):
            fail(response.split(":ERROR:", 1)[1])
        if response != f"{PROTOCOL}:ACQUIRED:{token}":
            fail("worktree single-flight guardian returned a malformed startup result")
        print(response)
    except BaseException:
        if server.fileno() >= 0:
            server.close()
        if not lock_handle.closed:
            lock_handle.close()
        try:
            socket_name.unlink()
        except FileNotFoundError:
            pass
        raise


def release(lock_name, token):
    socket_name = server_path(lock_name)
    client_name = control_root() / f"c-{os.getpid()}-{secrets.token_hex(4)}"
    client = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        client.bind(str(client_name))
        client.settimeout(CONTROL_TIMEOUT_SECONDS)
        client.sendto(token.encode("ascii"), str(socket_name))
        response = client.recv(4096).decode("ascii", "replace")
    finally:
        client.close()
        try:
            client_name.unlink()
        except FileNotFoundError:
            pass
    if response != "RELEASED:" + token:
        fail("worktree single-flight release was rejected")
    print(f"{PROTOCOL}:RELEASED:{token}")


def main():
    if len(sys.argv) != 5:
        fail("worktree single-flight helper received an invalid argument count")
    action, lock_name, token, owner_pid_raw = sys.argv[1:]
    try:
        owner_pid = int(owner_pid_raw)
    except ValueError:
        fail("worktree single-flight owner pid is invalid")
    if action == "acquire":
        if token or owner_pid < 1:
            fail("worktree single-flight acquire arguments are invalid")
        acquire(lock_name, owner_pid)
    elif action == "release":
        if not token:
            fail("worktree single-flight release token is missing")
        release(lock_name, token)
    else:
        fail("worktree single-flight action is invalid")


main()
]=]
