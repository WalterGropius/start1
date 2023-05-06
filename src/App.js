import { useState, useEffect } from 'react'
import { Canvas, extend, useLoader } from '@react-three/fiber'
import { OrbitControls, Environment, useTexture, Effects, MeshDistortMaterial, Html } from '@react-three/drei'
import { LUTPass, LUTCubeLoader } from 'three-stdlib'
import { Color } from 'three'

extend({ LUTPass })

function Grading() {
  const { texture3D } = useLoader(LUTCubeLoader, '/start1/cubicle-99.CUBE')
  return (
    <Effects>
      <lUTPass lut={texture3D} intensity={0.75} />
    </Effects>
  )
}

function Sphere({ setShowText, ...props }) {
  const texture = useTexture('/start1/terrazo.png')
  const [scale, setScale] = useState(1)

  const handleClick = () => {
    window.open('https://zenbau.haus/about1', 'noopener noreferrer')
  }

  return (
    <group>
      <mesh
        {...props}
        scale={scale}
        onClick={handleClick}
        onPointerOver={() => {
          setScale(1.2)
          setShowText(true)
        }}
        onPointerOut={() => {
          setScale(1)
          setShowText(false)
        }}>
        <sphereGeometry args={[1, 64, 64]} />
        <MeshDistortMaterial map={texture} clearcoat={1} clearcoatRoughness={0} roughness={0} metalness={0.5} />
      </mesh>
    </group>
  )
}

export default function App() {
  const [showText, setShowText] = useState(false)
  const [fontLoaded, setFontLoaded] = useState(false)

  useEffect(() => {
    async function loadFont() {
      try {
        const font = new FontFace('Poppins', "url('/start1/Poppins-Black.woff ')")
        await font.load()
        document.fonts.add(font)
        setFontLoaded(true)
      } catch (error) {
        console.error('Error loading the font: \n', error)
      }
    }

    loadFont()
  }, [])

  return (
    <>
      <Canvas frameloop="demand" camera={{ position: [0, 0, 5], fov: 45 }}>
        <ambientLight />
        <spotLight intensity={0.5} angle={0.2} penumbra={1} position={[5, 15, 10]} />
        <Sphere setShowText={setShowText} />
        <Grading />
        <Environment preset="forest" background blur={1} />
        <OrbitControls enableZoom={true} autoRotate={true} maxZoom={10} minZoom={10} />
      </Canvas>
      {fontLoaded && (
        <div
          style={{
            display: showText ? 'block' : 'none',
            position: 'absolute',
            top: '50%',
            left: '50%',
            transform: 'translate(-50%, -50%)',
            fontSize: '3rem',
            fontWeight: 'bold',
            fontFamily: 'Poppins',
            pointerEvents: 'none',
          }}>
          V S T U P T E
        </div>
      )}
    </>
  )
}
