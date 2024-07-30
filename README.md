# takeover.sh

A script to completely take over a running Linux system remotely, allowing you
to log into an in-memory Alpine rescue environment, unmount the original root
filesystem, and do anything you want, all without rebooting.

## WARNING WARNING WARNING WARNING

This is experimental. Do not use this script if you don't understand exactly
how it works. Do not use this script on any system you care about. Do not use
this script on any system you expect to be up. Do not run this script unless
you can afford to get physical access to fix a botched takeover. If anything
goes wrong, your system will most likely panic.

That said, this script will not (itself) make any permanent changes to your
existing root filesystem (assuming you run it from a tmpfs), so as long as you
can remotely reboot your box using an out-of-band mechanism, you *should* be OK.
But don't blame me if it eats your dog.

This script does not have any provisions for exiting *out* of the new
environment back into something sane. You *will* have to reboot when you're
done. If you get anything wrong, your machine won't boot. Tough luck.

## Compatibility

This script is designed for init systems that support `systemctl daemon-reexec`
or `telinit u` to reload the init binary. This includes systemd and sysvinit.
If your init system works a different way, you will have to adapt it, or this
might not work at all. You're on your own here.

## Building

Two variants of the script are provided: `takeover.sh` and `src/takeover.sh`.
The former is a self-contained script that embeds all the necessary files as
base64-encoded strings. The latter is a script that reads the necessary files
from the filesystem (i.e., the `stage1.sh` and `stage2.sh` scripts), and is
intended for development and testing.

To build the self-contained script, run `sh ./build_standalone.sh`. This will
create a `takeover.sh` script in the current directory. You can then run this
script directly on the target system.

## Usage

1. Shut down as many services as you can on your host.
2. Ensure that networking (including DNS) still works after you've shut down
   the services.
3. Run `sh ./takeover.sh` and follow the prompts. You could customize several
   parameters including the Alpine branch, packages, and secondary SSH server
   port. Check `sh ./takeover.sh --help` for more information. By default,
   the script will use the `latest-stable` branch and setup a secondary SSH
   server on port 2222.

If everything worked, congratulations! You may now use your new SSH session
to kill any remaining old daemons (`kill -9` is recommended to make sure they
don't try to do anything silly during shutdown), and then unmount all
filesystems under `/old_root`, including `/old_root` itself. You may want to
first copy `/old_root/lib/modules` into your new tmpfs in case you need any old
kernel modules.

You are now running entirely from RAM and should be able to do as you please.
Note that you may still have to clean up LVM volumes (`dmsetup` is your friend)
and similar before you can safely repartition your disk and install Gentoo
Linux, which is of course the whole reason you're doing this crazy thing to
begin with.

## Further reading

I've been pointed to
[this StackExchange answer](http://unix.stackexchange.com/questions/226872/how-to-shrink-root-filesystem-without-booting-a-livecd/227318#227318)
which details how to manually perform a similar process, but using a subset of
the existing root filesystem instead of a rescue filesystem. This allows you
to keep (a new copy of) the existing init system running, as well as essential
daemons, and then go back to the original root filesystem once you're done. This
is a more useful version if, for example, you want to resize the original root
filesystem or re-configure disk partitions, but not actually install a different
distro, and you want to avoid rebooting at all.
