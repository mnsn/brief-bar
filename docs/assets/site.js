// BriefBar's website: the appearance switch, the showcase's tabs, copying the Homebrew command, the latest release,
// Pull Request Order's stages, pictures at full size and what appears as you scroll. The page works without it.
(() => {
    'use strict';

    window.briefBarSite = true;

    const root = document.documentElement;
    const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
    const systemDark = matchMedia('(prefers-color-scheme: dark)');
    const announcer = document.querySelector('[data-announce]');

    function announce(message) {
        if (!announcer) return;
        announcer.textContent = '';
        requestAnimationFrame(() => { announcer.textContent = message; });
    }

    // Appearance: the Mac's, unless the visitor picks the other one. The pictures and the browser's own colors follow
    // it through their media queries, which the page's own choice replaces.
    const THEME_KEY = 'briefbar-theme';
    const themeToggle = document.querySelector('[data-theme-toggle]');

    function chosenTheme() {
        const theme = root.dataset.theme;
        return theme === 'light' || theme === 'dark' ? theme : null;
    }

    function applyTheme(theme) {
        if (theme) root.dataset.theme = theme;
        else delete root.dataset.theme;
        const dark = theme ? theme === 'dark' : systemDark.matches;
        for (const source of document.querySelectorAll('source[data-dark]')) {
            // A dark picture's own condition, such as less motion, still applies whichever appearance shows.
            const also = source.dataset.dark;
            let media;
            if (!theme) media = also ? `${also} and (prefers-color-scheme: dark)` : '(prefers-color-scheme: dark)';
            else if (dark) media = also || 'all';
            else media = 'not all';
            if (source.media !== media) source.media = media;
        }
        for (const meta of document.querySelectorAll('meta[data-theme-color]')) {
            const scheme = meta.dataset.themeColor;
            meta.media = theme ? (theme === scheme ? 'all' : 'not all') : `(prefers-color-scheme: ${scheme})`;
        }
        themeToggle?.setAttribute('aria-label', dark ? 'Use the light appearance' : 'Use the dark appearance');
    }

    applyTheme(chosenTheme());
    systemDark.addEventListener('change', () => applyTheme(chosenTheme()));

    themeToggle?.addEventListener('click', () => {
        const system = systemDark.matches ? 'dark' : 'light';
        const next = (chosenTheme() || system) === 'dark' ? 'light' : 'dark';
        // Picking the Mac's own appearance goes back to following it.
        const theme = next === system ? null : next;
        try {
            if (theme) localStorage.setItem(THEME_KEY, theme);
            else localStorage.removeItem(THEME_KEY);
        } catch {
            // Private browsing may refuse storage; the choice then lasts for this page.
        }
        if (document.startViewTransition && !reduceMotion.matches) {
            document.startViewTransition(() => applyTheme(theme));
        } else {
            applyTheme(theme);
        }
    });

    // The navigation's line, once the page has scrolled.
    const nav = document.querySelector('[data-nav]');
    if (nav) {
        const update = () => nav.classList.toggle('is-scrolled', window.scrollY > 8);
        addEventListener('scroll', update, { passive: true });
        update();
    }

    // Copying the Homebrew command.
    for (const button of document.querySelectorAll('[data-copy]')) {
        let timer;
        button.addEventListener('click', async () => {
            try {
                await navigator.clipboard.writeText(button.dataset.copy);
            } catch {
                // Without the clipboard, select the command so that it can be copied by hand.
                const code = button.querySelector('code');
                if (code) getSelection()?.selectAllChildren(code);
                return;
            }
            button.classList.add('is-copied');
            announce('Copied the Homebrew command');
            clearTimeout(timer);
            timer = setTimeout(() => button.classList.remove('is-copied'), 1800);
        });
    }

    // What appears as you scroll, with the cards of a group one after another.
    for (const group of document.querySelectorAll('[data-stagger]')) {
        [...group.children].forEach((child, index) => child.style.setProperty('--stagger', `${index * 90}ms`));
    }
    const revealed = document.querySelectorAll('.reveal');
    if ('IntersectionObserver' in window) {
        const observer = new IntersectionObserver((entries) => {
            for (const entry of entries) {
                if (!entry.isIntersecting) continue;
                entry.target.classList.add('is-visible');
                observer.unobserve(entry.target);
            }
        }, { rootMargin: '0px 0px -8% 0px', threshold: 0.12 });
        revealed.forEach((element) => observer.observe(element));
    } else {
        revealed.forEach((element) => element.classList.add('is-visible'));
    }

    // The showcase's links to its pictures become tabs: arrow keys move between them, and on a wide screen they change
    // by themselves, each as its progress bar fills, until the visitor picks one. Pointing at them, or reaching them by
    // keyboard, pauses them. Until then, every picture shows.
    for (const showcase of document.querySelectorAll('[data-showcase]')) {
        const list = showcase.querySelector('[data-showcase-tabs]');
        const tabs = list ? [...list.querySelectorAll('a[href^="#"]')] : [];
        const panels = tabs.map((tab) => document.getElementById(tab.hash.slice(1)));
        if (!tabs.length || panels.includes(null)) continue;
        let current = 0;
        let autoplay = !reduceMotion.matches && matchMedia('(min-width: 961px)').matches;

        list.setAttribute('role', 'tablist');
        list.setAttribute('aria-orientation', 'vertical');
        if (list.dataset.label) list.setAttribute('aria-label', list.dataset.label);
        tabs.forEach((tab, index) => {
            tab.setAttribute('role', 'tab');
            tab.setAttribute('aria-controls', panels[index].id);
            panels[index].setAttribute('role', 'tabpanel');
            panels[index].setAttribute('aria-labelledby', tab.id);
        });

        const select = (index, focus) => {
            current = (index + tabs.length) % tabs.length;
            tabs.forEach((tab, position) => {
                const selected = position === current;
                tab.setAttribute('aria-selected', String(selected));
                tab.tabIndex = selected ? 0 : -1;
                panels[position].hidden = !selected;
            });
            if (focus) tabs[current].focus();
        };

        const stopAutoplay = () => {
            autoplay = false;
            showcase.classList.remove('is-autoplay');
        };

        const keys = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 };
        tabs.forEach((tab, index) => {
            tab.addEventListener('click', (event) => {
                event.preventDefault();
                stopAutoplay();
                select(index);
            });
            tab.addEventListener('keydown', (event) => {
                let next = null;
                if (event.key in keys) next = current + keys[event.key];
                else if (event.key === 'Home') next = 0;
                else if (event.key === 'End') next = tabs.length - 1;
                // Space, which would scroll the page from a link, picks the tab as Enter does.
                else if (event.key === ' ') next = index;
                if (next === null) return;
                event.preventDefault();
                stopAutoplay();
                select(next, true);
            });
        });

        select(current);
        showcase.classList.add('is-tabbed');

        if (autoplay) {
            showcase.classList.add('is-autoplay');
            showcase.addEventListener('animationend', (event) => {
                if (autoplay && event.animationName === 'showcase-progress') select(current + 1);
            });
            showcase.addEventListener('pointerenter', () => showcase.classList.add('is-paused'));
            showcase.addEventListener('pointerleave', () => showcase.classList.remove('is-paused'));
            showcase.addEventListener('focusin', () => showcase.classList.add('is-paused'));
            showcase.addEventListener('focusout', () => showcase.classList.remove('is-paused'));
            if ('IntersectionObserver' in window) {
                new IntersectionObserver(([entry]) => showcase.classList.toggle('is-offscreen', !entry.isIntersecting))
                    .observe(showcase);
            }
        }
    }

    // Pull Request Order: while it's on screen, the pull request moves a stage every 2.2 seconds, then starts again.
    for (const flow of document.querySelectorAll('[data-flow]')) {
        const stages = [...flow.querySelectorAll('[data-stage-status]')];
        const card = flow.querySelector('.flow__card');
        const status = flow.querySelector('[data-flow-status]');
        if (!stages.length || !card || !status) continue;
        let index = 0;
        let timer = null;

        const show = (next) => {
            index = next;
            stages.forEach((stage, position) => {
                stage.classList.toggle('is-active', position === index);
                stage.classList.toggle('is-done', position < index);
            });
            card.style.setProperty('--i', String(index));
            card.style.setProperty('--card-stage', stages[index].style.getPropertyValue('--stage'));
            status.textContent = stages[index].dataset.stageStatus;
        };

        const step = () => {
            if (index < stages.length - 1) {
                show(index + 1);
                return;
            }
            card.classList.add('is-leaving');
            setTimeout(() => {
                card.classList.add('is-jumping');
                show(0);
                void card.offsetWidth;
                card.classList.remove('is-jumping', 'is-leaving');
            }, 450);
        };

        if (reduceMotion.matches || !('IntersectionObserver' in window)) {
            show(1);
            continue;
        }
        show(0);
        new IntersectionObserver(([entry]) => {
            if (entry.isIntersecting && !timer) {
                timer = setInterval(step, 2200);
            } else if (!entry.isIntersecting && timer) {
                clearInterval(timer);
                timer = null;
            }
        }, { threshold: 0.4 }).observe(flow);
    }

    // Privacy's switches only show what each setting says; the real ones are in BriefBar's Settings.
    for (const toggle of document.querySelectorAll('.switch[role="switch"]')) {
        toggle.addEventListener('click', () => {
            toggle.setAttribute('aria-checked', String(toggle.getAttribute('aria-checked') !== 'true'));
        });
    }

    // A picture at full size, in the appearance it's shown in. With a modifier key, the link opens as links do.
    const lightbox = document.querySelector('[data-lightbox]');
    if (lightbox && typeof lightbox.showModal === 'function') {
        const large = lightbox.appendChild(document.createElement('img'));
        document.addEventListener('click', (event) => {
            const link = event.target.closest?.('a[data-zoom]');
            if (!link || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return;
            const picture = link.querySelector('img');
            if (!picture) return;
            event.preventDefault();
            large.src = picture.currentSrc || picture.src;
            large.alt = picture.alt;
            lightbox.showModal();
        });
        lightbox.addEventListener('click', () => lightbox.close());
        lightbox.addEventListener('close', () => large.removeAttribute('src'));
    }

    // The latest release, in the pill above the title, from GitHub's API: asked at most once an hour in a tab, whether
    // or not it answered, and nothing changes when it doesn't.
    const pill = document.querySelector('[data-release]');
    const label = pill?.querySelector('[data-release-label]');
    if (pill && label) {
        latestRelease().then((release) => {
            if (!release) return;
            label.textContent = `BriefBar ${release.version} is out · What’s new`;
            pill.href = release.url;
        });
    }

    async function latestRelease() {
        const KEY = 'briefbar-release';
        const save = (value) => {
            try {
                sessionStorage.setItem(KEY, JSON.stringify(value));
            } catch {
                // Storage is off: it's asked again next time.
            }
        };
        try {
            const saved = JSON.parse(sessionStorage.getItem(KEY));
            // Within the hour, the release it found then, or nothing if it didn't find one.
            if (saved && Date.now() - saved.at < 3600 * 1000) return saved.version && saved.url ? saved : null;
        } catch {
            // Nothing saved, or storage is off.
        }
        save({ at: Date.now() });
        try {
            const response = await fetch('https://api.github.com/repos/mnsn/brief-bar/releases/latest', {
                headers: { Accept: 'application/vnd.github+json' },
            });
            if (!response.ok) return null;
            const json = await response.json();
            const version = String(json.tag_name || '').replace(/^v/, '');
            if (!/^\d+(\.\d+){1,3}$/.test(version)) return null;
            const url = /^https:\/\/github\.com\/mnsn\/brief-bar\/releases\/tag\/[\w.-]+$/.test(json.html_url)
                ? json.html_url
                : 'https://github.com/mnsn/brief-bar/releases/latest';
            const release = { version, url, at: Date.now() };
            save(release);
            return release;
        } catch {
            return null;
        }
    }
})();
