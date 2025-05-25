# vhd-launcher

* package windows game directory as a single vhd file
* vhd supports compression
* download to tf card and start playing directly without decompression
* redirect individual game save folder to a central folder such as C:\game-saves\xxx, so that we can cloud sync

# usage

prepare a vhd file containing the game. Windows Disk Manager supports create and attach vhd file out of box, just create a vhd, mount it and copy the game files.

write a ini file to describe the game directory layout, such as ninja-gaiden1.vhd and ninja-gaiden1.ini

```
readonly=true
launchDriveLetter=Z
launchExe=Ninja Gaiden Sigma.exe
sourceSaveDir=C:\Users\taowe\Documents\KoeiTecmo\NINJAGAIDENSIGMA
targetSaveDir=C:\game-save\ninja-gaiden1
```

then launch the vhd

```
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\workspace\vhd-launcher\vhd-launcher.ps1" -VhdPath "C:\workspace\vhd-launcher\ninja-gaiden1.vhd"
```

this will mount the vhd and launch the game, it will also

* link the save dir `C:\Users\taowe\Documents\KoeiTecmo\NINJAGAIDENSIGMA` <-> `C:\game-save\ninja-gaiden1`
* create a desktop link (optionally, you can provide a ico file to make it pretty)

the files can be copied to other machines

# MSI Claw Handheld

* 体感助手 https://www.bilibili.com/video/BV1xHo6YgEfK/
* Handheld Companion https://github.com/Valkirie/HandheldCompanion
