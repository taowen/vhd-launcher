# vhd-launcher

Download and launch windows game in sdcard as a single file. Save the time of downloading and speed up game loading.

* mount vhd file as Z drive and launch game exe file
* vhd supports compression
* redirect individual game save folder to a central folder such as C:\game-saves\xxx, so that we can cloud sync

# usage

prepare a vhd file and ini file, such as ninja-gaiden1.vhd and ninja-gaiden1.ini

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
* create a `C:\workspace\vhd-launcher\ninja-gaiden1.lnk` `C:\workspace\vhd-launcher\ninja-gaiden1.ico` file

you can copy the lnk and ico file to windows desktop to use as shortcut