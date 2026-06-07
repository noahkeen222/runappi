import './style.css';

document.querySelector('#app').innerHTML = `
  <div class="min-h-screen bg-base-200 flex flex-col">

    <!-- Navbar -->
    <div class="navbar bg-base-100 shadow-sm px-6">
      <div class="flex-1">
        <a class="btn btn-ghost text-xl font-bold tracking-tight">MyApp</a>
      </div>
      <div class="flex-none gap-2">
        <a class="btn btn-ghost btn-sm">Docs</a>
        <a class="btn btn-primary btn-sm">Get Started</a>
      </div>
    </div>

    <!-- Hero -->
    <main class="flex-1 flex flex-col items-center justify-center px-4 py-20 text-center">
      <div class="badge badge-primary badge-outline mb-4 text-xs tracking-widest uppercase">
        Vite + DaisyUI
      </div>
      <h1 class="text-5xl font-extrabold tracking-tight mb-4 max-w-2xl leading-tight">
        Build something <span class="text-primary">remarkable.</span>
      </h1>
      <p class="text-base-content/60 text-lg max-w-md mb-8">
        A minimal starter with DaisyUI components and a clean custom style layer.
        Edit <code class="font-mono bg-base-300 px-1.5 py-0.5 rounded text-sm">main.js</code> to begin.
      </p>
      <div class="flex gap-3 flex-wrap justify-center">
        <button class="btn btn-primary btn-lg" id="cta-btn">Get started</button>
        <button class="btn btn-ghost btn-lg">Learn more</button>
      </div>

      <!-- Toast trigger feedback -->
      <div id="toast-container" class="toast toast-top toast-center hidden z-50">
        <div class="alert alert-success shadow-lg">
          <span>🎉 It's working! Start building.</span>
        </div>
      </div>
    </main>

    <!-- Cards -->
    <section class="max-w-4xl mx-auto w-full px-4 pb-20 grid grid-cols-1 md:grid-cols-3 gap-4">
      ${[
        { icon: '⚡', title: 'Vite', desc: 'Blazing fast HMR and build tooling out of the box.' },
        { icon: '🎨', title: 'DaisyUI', desc: 'Semantic Tailwind component classes, no JS overhead.' },
        { icon: '🧩', title: 'Composable', desc: 'Mix DaisyUI tokens with your own custom CSS layer.' },
      ].map(({ icon, title, desc }) => `
        <div class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow duration-200">
          <div class="card-body">
            <div class="text-3xl mb-1">${icon}</div>
            <h2 class="card-title">${title}</h2>
            <p class="text-base-content/60 text-sm">${desc}</p>
          </div>
        </div>
      `).join('')}
    </section>

    <!-- Footer -->
    <footer class="footer footer-center py-6 bg-base-100 text-base-content/40 text-sm border-t border-base-300">
      <p>Built with Vite · DaisyUI · Tailwind CSS</p>
    </footer>

  </div>
`;

// CTA button — shows a toast
document.getElementById('cta-btn').addEventListener('click', () => {
  const toast = document.getElementById('toast-container');
  toast.classList.remove('hidden');
  setTimeout(() => toast.classList.add('hidden'), 3000);
});