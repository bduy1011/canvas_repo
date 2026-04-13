# Unity 3D - Bat Huong (Do Tho Cung)

Project nay da duoc gan san man hinh Flutter de nhung Unity, phuc vu hien thi
model 3D do tho cung (bat huong) co the xoay.

## 1) Da them trong Flutter

- Dependency: `flutter_unity_widget`
- Man hinh 3D: `lib/demos/unity_bat_huong_demo.dart`
- Entry app: `lib/main.dart` -> `UnityBatHuongDemoPage`

## 2) Tao Unity project cho bat huong

1. Tao Unity project moi (3D URP hoac Built-in deu duoc).
2. Import model bat huong (`.fbx`, `.obj`, `.glb`) vao Unity.
3. Dat model root trong scene voi ten `BatHuongRoot`.
4. Tao 2 script C# sau va gan vao object trong scene.

### Script 1: BatHuongController.cs (gan vao BatHuongRoot)

```csharp
using UnityEngine;

public class BatHuongController : MonoBehaviour
{
	[SerializeField] private float autoRotateSpeed = 20f;

	private void Update()
	{
		if (Mathf.Abs(autoRotateSpeed) > 0.01f)
		{
			transform.Rotate(0f, autoRotateSpeed * Time.deltaTime, 0f, Space.World);
		}
	}

	public void RotateY(string degrees)
	{
		if (float.TryParse(degrees, out var y))
		{
			transform.Rotate(0f, y, 0f, Space.World);
		}
	}

	public void SetAutoRotateSpeed(string speed)
	{
		if (float.TryParse(speed, out var s))
		{
			autoRotateSpeed = s;
		}
	}

	public void ResetPose(string _)
	{
		transform.rotation = Quaternion.identity;
		transform.position = Vector3.zero;
	}
}
```

### Script 2: SceneController.cs (gan vao object ten SceneController)

```csharp
using UnityEngine;

public class SceneController : MonoBehaviour
{
	public void LoadModelByKeyword(string keyword)
	{
		// Ban co the map keyword -> prefab/asset bundle/server model tai day.
		// Vi du:
		// - "bat huong" -> Prefab_BatHuongDong
		// - "altar" -> Prefab_AltarSet
		Debug.Log("Flutter keyword: " + keyword);
	}
}
```

## 3) Export Unity as Library vao Flutter

1. Cai dat theo huong dan package:
   https://pub.dev/packages/flutter_unity_widget
2. Trong Unity, export Android/iOS theo huong dan cua plugin.
3. Copy phan export vao project Flutter `example` theo dung cau truc plugin yeu cau.
4. Dam bao Android/iOS build settings dung version SDK va Gradle.

## 4) Chay app

```bash
cd example
flutter pub get
flutter run -d <android-device-id>
```

Luu y: Unity widget hien chu yeu ho tro Android/iOS. Neu chay Web/Windows,
man hinh se bao nen doi sang emulator/phone.
