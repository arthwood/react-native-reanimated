const fs = require('fs');

function patchFile(path, find, replace) {
  let data = fs.readFileSync(path, 'utf8');
  data = data.replace(find, replace);
  fs.writeFileSync(path, data);
}

const command = process.argv[2];

if (command === 'setBundleIdentifier') {
  patchFile(
    'app.json',
    '"ios": {',
    '"ios": {"bundleIdentifier":"com.swmansion.app",'
  );

  patchFile(
    'app.json',
    '"android": {',
    '"android": {"package": "com.swmansion.app",'
  );
}

if (command === 'setupFabricIOS') {
  patchFile(
    'ios/Podfile.properties.json',
    '"expo.jsEngine"',
    '"newArchEnabled":"true","expo.jsEngine"'
  );
}

if (command === 'setupFabricAndroid') {
  patchFile(
    'android/gradle.properties',
    'newArchEnabled=false',
    'newArchEnabled=true'
  );
}
